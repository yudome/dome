#include "brokerdisplay.h"

#include <QDebug>
#include <QSocketNotifier>

#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <utility>
#include <vector>

namespace {

constexpr uint16_t CMD_ATTACH = 1;
constexpr uint16_t CMD_COMMIT = 2;
constexpr uint16_t CMD_QUERY_FORMAT = 6;

constexpr uint16_t EV_HELLO = 1;
constexpr uint16_t EV_SURFACE = 2;
constexpr uint16_t EV_FRAME = 3;
constexpr uint16_t EV_KEY = 5;
constexpr uint16_t EV_BTN = 6;
constexpr uint16_t EV_ABS = 7;
constexpr uint16_t EV_WHEEL = 9;
constexpr uint16_t EV_GRAB = 10;
constexpr uint16_t EV_FOCUS = 11;
constexpr uint16_t EV_POINTER = 12;
constexpr uint16_t EV_FORMAT = 16;

constexpr uint32_t CAP_KEYBOARD = 1u << 0;
constexpr uint32_t CAP_ABS_POINTER = 1u << 1;
constexpr uint32_t CAP_FOCUS_EVENTS = 1u << 5;
constexpr uint32_t CAP_DMABUF = 1u << 7;
constexpr uint32_t CAP_MODIFIERS = 1u << 8;

constexpr uint16_t F_FOCUSED = 1u << 1;

constexpr uint16_t PROTO_VERSION = 2;

struct Cmd {
	uint16_t type;
	uint16_t flags;
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	uint32_t offset;
	uint32_t fourcc;
	uint64_t modifier;
	uint32_t seq;
	uint32_t reserved;
} __attribute__((packed));

struct Pkt {
	uint16_t type;
	uint16_t flags;
	uint32_t seq;
	int32_t x;
	int32_t y;
	uint32_t w0;
	uint32_t w1;
} __attribute__((packed));

static_assert(sizeof(Cmd) == 40, "broker command is 40 bytes");
static_assert(sizeof(Pkt) == 24, "broker packet is 24 bytes");

bool waitWritable(int fd) {
	struct pollfd pfd = { fd, POLLOUT, 0 };
	for (int attempt = 0; attempt < 4; attempt++) {
		const int r = ::poll(&pfd, 1, 20);
		if (r > 0) return (pfd.revents & POLLOUT) != 0;
		if (r < 0 && errno != EINTR) return false;
	}
	return false;
}

bool writeAll(int fd, const void *data, size_t size) {
	const char *cursor = static_cast<const char *>(data);
	while (size > 0) {
		const ssize_t n = ::send(fd, cursor, size, MSG_NOSIGNAL);
		if (n > 0) {
			cursor += n;
			size -= size_t(n);
			continue;
		}
		if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && waitWritable(fd)) continue;
		if (n < 0 && errno == EINTR) continue;
		return false;
	}
	return true;
}

} // namespace

struct BrokerDisplay::Impl {
	int listenFd = -1;
	int clientFd = -1;
	uint8_t rx[40] = {};
	size_t rxlen = 0;
	int rxfd = -1;
	QSocketNotifier *listenNotifier = nullptr;
	QSocketNotifier *clientNotifier = nullptr;
	QString path;
	bool running = false;
	bool focused = false;
	bool pointer = false;
	int width = 0;
	int height = 0;
	int refresh = 0;
	uint32_t seq = 0;
	std::mutex mutex;
	QmpDisplay::Frame pending;
	int attachedFd = -1;
	uint32_t attachedFourcc = 0;
	uint32_t attachedModLo = 0;
	uint32_t attachedModHi = 0;
	uint32_t attachedW = 0;
	uint32_t attachedH = 0;
	uint32_t attachedStride = 0;
	uint32_t attachedOffset = 0;
	BrokerDisplay *q = nullptr;

	void packet(uint16_t type, int32_t x = 0, int32_t y = 0, uint32_t w0 = 0, uint32_t w1 = 0) {
		if (clientFd < 0) return;
		Pkt p{};
		p.type = type;
		p.flags = focused ? F_FOCUSED : 0;
		p.seq = seq++;
		p.x = x;
		p.y = y;
		p.w0 = w0;
		p.w1 = w1;
		if (!writeAll(clientFd, &p, sizeof(p))) qWarning() << "broker send failed" << strerror(errno);
	}

	void handshake() {
		const uint32_t caps = CAP_KEYBOARD | CAP_ABS_POINTER | CAP_FOCUS_EVENTS | CAP_DMABUF | CAP_MODIFIERS;
		packet(EV_HELLO, 0, 0, PROTO_VERSION, caps);
		packet(EV_SURFACE, width, height, uint32_t(refresh), 0);
		packet(EV_FOCUS, focused ? 1 : 0);
		packet(EV_GRAB, 0);
		packet(EV_FRAME);
	}

	void closeAttached() {
		if (attachedFd >= 0) ::close(attachedFd);
		attachedFd = -1;
	}

	void dropClient() {
		if (clientNotifier) {
			clientNotifier->setEnabled(false);
			clientNotifier->deleteLater();
			clientNotifier = nullptr;
		}
		if (clientFd >= 0) ::close(clientFd);
		clientFd = -1;
		rxlen = 0;
		if (rxfd >= 0) ::close(rxfd);
		rxfd = -1;
		closeAttached();
		std::lock_guard<std::mutex> lock(mutex);
		if (pending.fd >= 0) ::close(pending.fd);
		pending = QmpDisplay::Frame{};
	}

	void stop() {
		dropClient();
		if (listenNotifier) {
			listenNotifier->setEnabled(false);
			listenNotifier->deleteLater();
			listenNotifier = nullptr;
		}
		if (listenFd >= 0) ::close(listenFd);
		listenFd = -1;
		if (!path.isEmpty()) ::unlink(path.toLocal8Bit().constData());
		path.clear();
		running = false;
		focused = false;
		pointer = false;
		seq = 0;
	}

	void acceptClient() {
		const int fd = ::accept4(listenFd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
		if (fd < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK) qWarning() << "broker accept" << strerror(errno);
			return;
		}
		dropClient();
		clientFd = fd;
		clientNotifier = new QSocketNotifier(clientFd, QSocketNotifier::Read, q);
		QObject::connect(clientNotifier, &QSocketNotifier::activated, q, [this]() { readCommands(); });
		handshake();
		qInfo() << "broker client attached" << path;
	}

	void command(const Cmd &cmd, int incomingFd) {
		switch (cmd.type) {
		case CMD_ATTACH:
			closeAttached();
			attachedFd = incomingFd;
			attachedFourcc = cmd.fourcc;
			attachedModLo = uint32_t(cmd.modifier & 0xffffffffu);
			attachedModHi = uint32_t(cmd.modifier >> 32);
			attachedW = cmd.width;
			attachedH = cmd.height;
			attachedStride = cmd.stride;
			attachedOffset = cmd.offset;
			return;
		case CMD_COMMIT:
			if (attachedFd < 0 || attachedW == 0 || attachedH == 0) {
				closeAttached();
				return;
			}
			{
				std::lock_guard<std::mutex> lock(mutex);
				if (pending.fd >= 0) ::close(pending.fd);
				pending = QmpDisplay::Frame{};
				pending.fd = attachedFd;
				pending.fourcc = attachedFourcc;
				pending.modLo = attachedModLo;
				pending.modHi = attachedModHi;
				pending.w = int(attachedW);
				pending.h = int(attachedH);
				pending.bw = attachedW;
				pending.bh = attachedH;
				pending.stride = attachedStride;
				pending.offset = attachedOffset;
			}
			attachedFd = -1;
			emit q->frameReady();
			return;
		case CMD_QUERY_FORMAT: {
			const uint32_t fourcc = cmd.fourcc;
			const bool ok = fourcc == 0x34325258 || fourcc == 0x34325241;
			packet(EV_FORMAT, ok ? 1 : 0, int32_t(fourcc),
			       uint32_t(cmd.modifier & 0xffffffffu), uint32_t(cmd.modifier >> 32));
			return;
		}
		default:
			return;
		}
	}

	void readCommands() {
		while (true) {
			char control[CMSG_SPACE(sizeof(int) * 4)];
			struct iovec iov = { rx + rxlen, sizeof(rx) - rxlen };
			struct msghdr msg{};
			msg.msg_iov = &iov;
			msg.msg_iovlen = 1;
			msg.msg_control = control;
			msg.msg_controllen = sizeof(control);
			const ssize_t n = ::recvmsg(clientFd, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
			if (n < 0) {
				if (errno == EAGAIN || errno == EWOULDBLOCK) return;
				if (errno == EINTR) continue;
				qWarning() << "broker recv" << strerror(errno);
				dropClient();
				return;
			}
			if (n == 0) {
				qInfo() << "broker client detached";
				dropClient();
				return;
			}

			for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
				if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) continue;
				const size_t payload = cmsg->cmsg_len - CMSG_LEN(0);
				const size_t count = payload / sizeof(int);
				for (size_t k = 0; k < count; k++) {
					int fd = -1;
					memcpy(&fd, CMSG_DATA(cmsg) + k * sizeof(int), sizeof(int));
					if (rxfd < 0) rxfd = fd;
					else ::close(fd);
				}
			}

			rxlen += size_t(n);
			if (rxlen < sizeof(rx)) continue;

			Cmd cmd{};
			memcpy(&cmd, rx, sizeof(cmd));
			const int recordFd = rxfd;
			rxlen = 0;
			rxfd = -1;
			command(cmd, recordFd);
			if (recordFd >= 0 && cmd.type != CMD_ATTACH) ::close(recordFd);
		}
	}

	QmpDisplay::Frame takeFrame() {
		std::lock_guard<std::mutex> lock(mutex);
		QmpDisplay::Frame frame = pending;
		pending = QmpDisplay::Frame{};
		return frame;
	}
};

BrokerDisplay::BrokerDisplay(QObject *parent) : QObject(parent), d(new Impl) {
	d->q = this;
}

BrokerDisplay::~BrokerDisplay() {
	d->stop();
}

bool BrokerDisplay::start(const QString &socketPath, int width, int height, int refreshMilliHz) {
	d->stop();
	if (socketPath.isEmpty() || width <= 0 || height <= 0) return false;

	const QByteArray path = socketPath.toLocal8Bit();
	struct sockaddr_un addr{};
	addr.sun_family = AF_UNIX;
	if (path.size() >= int(sizeof(addr.sun_path))) {
		emit failed("broker path too long");
		return false;
	}
	memcpy(addr.sun_path, path.constData(), size_t(path.size()));

	const int probe = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (probe >= 0) {
		const bool inUse = ::connect(probe, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) == 0;
		::close(probe);
		if (inUse) {
			emit failed("broker socket already in use");
			return false;
		}
	}
	::unlink(path.constData());

	const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		emit failed("broker socket");
		return false;
	}
	if (::bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0 || ::listen(fd, 1) < 0) {
		qWarning() << "broker bind" << socketPath << strerror(errno);
		::close(fd);
		::unlink(path.constData());
		emit failed("broker bind");
		return false;
	}
	::chmod(path.constData(), 0600);

	d->listenFd = fd;
	d->path = socketPath;
	d->width = width;
	d->height = height;
	d->refresh = refreshMilliHz;
	d->running = true;
	d->listenNotifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
	connect(d->listenNotifier, &QSocketNotifier::activated, this, [this]() { d->acceptClient(); });
	return true;
}

void BrokerDisplay::stop() {
	d->stop();
}

bool BrokerDisplay::running() const {
	return d->running;
}

bool BrokerDisplay::attached() const {
	return d->clientFd >= 0;
}

void BrokerDisplay::setSurfaceSize(int width, int height) {
	if (width <= 0 || height <= 0) return;
	if (d->width == width && d->height == height) return;
	d->width = width;
	d->height = height;
	if (d->clientFd >= 0) d->packet(EV_SURFACE, width, height, uint32_t(d->refresh), 0);
}

void BrokerDisplay::frameConsumed() {
	d->packet(EV_FRAME);
}

void BrokerDisplay::sendKey(int evdev, bool down) {
	d->packet(EV_KEY, evdev, down ? 1 : 0);
}

void BrokerDisplay::sendButton(int evdev, bool down) {
	d->packet(EV_BTN, evdev, down ? 1 : 0);
}

void BrokerDisplay::sendAbs(int x, int y) {
	d->packet(EV_ABS, x, y, uint32_t(d->width), uint32_t(d->height));
}

void BrokerDisplay::sendWheel(int vertical, int horizontal) {
	d->packet(EV_WHEEL, vertical, horizontal);
}

void BrokerDisplay::sendFocus(bool focused) {
	if (d->focused == focused) return;
	d->focused = focused;
	d->packet(EV_FOCUS, focused ? 1 : 0);
}

void BrokerDisplay::sendPointer(bool inside) {
	if (d->pointer == inside) return;
	d->pointer = inside;
	d->packet(EV_POINTER, inside ? 1 : 0);
}

QmpDisplay::Frame BrokerDisplay::takeFrame() {
	return d->takeFrame();
}
