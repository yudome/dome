#include "vmdisplay.h"
#include "qmp.h"
#include "brokerdisplay.h"
#include "inhibitor.h"
#include "pointerlock.h"

#include <QGuiApplication>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QOpenGLContext>
#include <QDebug>
#include <QTimer>
#include <QOpenGLFunctions>
#include <QQuickWindow>
#include <QScreen>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QtQuick/qsgtexture_platform.h>
#include <QWheelEvent>
#include <QtGui/qopenglcontext_platform.h>
#include <QtGui/qguiapplication_platform.h>
#include <qpa/qplatformwindow_p.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <sys/mman.h>
#include <unistd.h>

namespace {

PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTarget = nullptr;
PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;

void loadEgl() {
	if (createImage && imageTarget && destroyImage) return;
	createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
	imageTarget = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
	destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
}

int qnumForEvdev(int evdev) {
	switch (evdev) {
	case 1: return 0x01;
	case 2: return 0x02;
	case 3: return 0x03;
	case 4: return 0x04;
	case 5: return 0x05;
	case 6: return 0x06;
	case 7: return 0x07;
	case 8: return 0x08;
	case 9: return 0x09;
	case 10: return 0x0a;
	case 11: return 0x0b;
	case 12: return 0x0c;
	case 13: return 0x0d;
	case 14: return 0x0e;
	case 15: return 0x0f;
	case 16: return 0x10;
	case 17: return 0x11;
	case 18: return 0x12;
	case 19: return 0x13;
	case 20: return 0x14;
	case 21: return 0x15;
	case 22: return 0x16;
	case 23: return 0x17;
	case 24: return 0x18;
	case 25: return 0x19;
	case 26: return 0x1a;
	case 27: return 0x1b;
	case 28: return 0x1c;
	case 29: return 0x1d;
	case 30: return 0x1e;
	case 31: return 0x1f;
	case 32: return 0x20;
	case 33: return 0x21;
	case 34: return 0x22;
	case 35: return 0x23;
	case 36: return 0x24;
	case 37: return 0x25;
	case 38: return 0x26;
	case 39: return 0x27;
	case 40: return 0x28;
	case 41: return 0x29;
	case 42: return 0x2a;
	case 43: return 0x2b;
	case 44: return 0x2c;
	case 45: return 0x2d;
	case 46: return 0x2e;
	case 47: return 0x2f;
	case 48: return 0x30;
	case 49: return 0x31;
	case 50: return 0x32;
	case 51: return 0x33;
	case 52: return 0x34;
	case 53: return 0x35;
	case 54: return 0x36;
	case 55: return 0x37;
	case 56: return 0x38;
	case 57: return 0x39;
	case 58: return 0x3a;
	case 59: return 0x3b;
	case 60: return 0x3c;
	case 61: return 0x3d;
	case 62: return 0x3e;
	case 63: return 0x3f;
	case 64: return 0x40;
	case 65: return 0x41;
	case 66: return 0x42;
	case 67: return 0x43;
	case 68: return 0x44;
	case 87: return 0x57;
	case 88: return 0x58;
	case 96: return 0x60;
	case 97: return 0x61;
	case 98: return 0x62;
	case 99: return 0x63;
	case 100: return 0x64;
	case 102: return 0x66;
	case 103: return 0x67;
	case 104: return 0x68;
	case 105: return 0x69;
	case 106: return 0x6a;
	case 107: return 0x6b;
	case 108: return 0x6c;
	case 109: return 0x6d;
	case 110: return 0x6e;
	case 111: return 0x6f;
	case 113: return 0x71;
	case 114: return 0x72;
	case 115: return 0x73;
	case 116: return 0x74;
	case 117: return 0x75;
	case 118: return 0x76;
	case 119: return 0x77;
	case 121: return 0x79;
	case 122: return 0x7a;
	case 125: return 0x7d;
	case 126: return 0x7e;
	case 127: return 0x7f;
	default: return -1;
	}
}

} // namespace

struct VmDisplay::Private {
	QmpDisplay *display = nullptr;
	EGLDisplay eglDisplay = EGL_NO_DISPLAY;
	EGLImageKHR image = EGL_NO_IMAGE_KHR;
	GLuint texture = 0;
	int textureW = 0;
	int textureH = 0;
	bool y0top = false;
	QSGTexture *nodeTexture = nullptr;
	QImage cursorImage;
	QRectF dstRect;
	int hotX = 0;
	int hotY = 0;
	bool cursorVisible = true;
	qreal cursorScale = 1.0;
	int mapFd = -1;
	void *mapBase = nullptr;
	void *mapData = nullptr;
	size_t mapSize = 0;
	size_t mapMapSize = 0;
	int mapW = 0;
	int mapH = 0;
	int mapStride = 0;
	int mapOffset = 0;
	bool mapMode = false;
	int updateX = 0;
	int updateY = 0;
	int updateW = 0;
	int updateH = 0;
	bool updatePending = false;
	BrokerDisplay *broker = nullptr;
	bool brokerFocused = false;
	bool brokerPointer = false;
	WaylandInhibitor inhibitor;
	WaylandPointerLock pointerLock;
	bool grabbed = false;
	int swallowKey = -1;
	double relX = 0;
	double relY = 0;
	QMetaObject::Connection activeConnection;
	bool pointerInside = false;
	int lastX = -1;
	int lastY = -1;
};

VmDisplay::VmDisplay(QQuickItem *parent) : QQuickItem(parent), d(new Private) {
	setFlag(ItemHasContents, true);
	setAcceptedMouseButtons(Qt::AllButtons);
	setAcceptHoverEvents(true);
	d->display = new QmpDisplay(this);
	d->broker = new BrokerDisplay(this);
	connect(d->display, &QmpDisplay::frameReady, this, [this]() { update(); });
	connect(d->display, &QmpDisplay::mapReady, this, [this]() { update(); });
	connect(d->display, &QmpDisplay::pixmapReady, this, [this]() { update(); });
	connect(d->display, &QmpDisplay::updated, this, [this](int x, int y, int w, int h) {
		if (d->mapMode) {
			if (!d->updatePending) {
				d->updateX = x; d->updateY = y; d->updateW = w; d->updateH = h;
				d->updatePending = true;
			} else {
				const int x0 = qMin(d->updateX, x);
				const int y0 = qMin(d->updateY, y);
				const int x1 = qMax(d->updateX + d->updateW, x + w);
				const int y1 = qMax(d->updateY + d->updateH, y + h);
				d->updateX = x0; d->updateY = y0; d->updateW = x1 - x0; d->updateH = y1 - y0;
			}
		}
		update();
	});
	connect(d->display, &QmpDisplay::cursorImage, this, [this](const QImage &image, int hotX, int hotY) {
		d->cursorImage = image;
		d->hotX = hotX;
		d->hotY = hotY;
		applyCursor();
	});
	connect(d->display, &QmpDisplay::mouseState, this, [this](int, int, bool visible) {
		if (visible == d->cursorVisible) return;
		d->cursorVisible = visible;
		applyCursor();
	});
	connect(d->display, &QmpDisplay::failed, this, [this](const QString &message) {
		m_error = message;
		m_running = false;
		emit errorChanged();
		emit runningChanged();
		QTimer::singleShot(1000, this, [this]() { maybeStart(); });
	});
	connect(d->broker, &BrokerDisplay::frameReady, this, [this]() { update(); });
	connect(d->broker, &BrokerDisplay::failed, this, [this](const QString &message) {
		m_error = message;
		emit errorChanged();
		QTimer::singleShot(1000, this, [this]() { if (!m_running) maybeStart(); });
	});
	connect(this, &QQuickItem::activeFocusChanged, this, &VmDisplay::updateBrokerFocus);
	d->pointerLock.onMotion([this](double dx, double dy) {
		d->relX += dx;
		d->relY += dy;
		const int x = int(d->relX);
		const int y = int(d->relY);
		d->relX -= x;
		d->relY -= y;
		if (d->broker) d->broker->sendRel(x, y);
	});
	d->pointerLock.onLost([this]() {
		QMetaObject::invokeMethod(this, [this]() { setGrab(false); }, Qt::QueuedConnection);
	});
}

VmDisplay::~VmDisplay() {
	if (d->broker) d->broker->stop();
	if (d->nodeTexture) delete d->nodeTexture;
	if (d->texture) {
		QOpenGLContext *ctx = QOpenGLContext::currentContext();
		if (ctx) ctx->functions()->glDeleteTextures(1, &d->texture);
	}
	if (d->image != EGL_NO_IMAGE_KHR && d->eglDisplay != EGL_NO_DISPLAY) destroyImage(d->eglDisplay, d->image);
	if (d->mapBase) munmap(d->mapBase, d->mapMapSize);
	if (d->mapFd >= 0) close(d->mapFd);
	delete d;
}

void VmDisplay::setQmp(const QString &value) {
	if (m_qmp == value) return;
	m_qmp = value;
	emit qmpChanged();
	stopSource();
	d->cursorImage = QImage();
	d->cursorVisible = true;
	applyCursor();
	maybeStart();
}

void VmDisplay::applyCursor() {
	if (!m_broker.isEmpty()) return;
	if (m_qmp.isEmpty()) {
		unsetCursor();
		return;
	}
	if (!d->cursorVisible || d->cursorImage.isNull()) {
		setCursor(Qt::BlankCursor);
		return;
	}
	const qreal dpr = window() ? window()->devicePixelRatio() : 1.0;
	const qreal scale = d->cursorScale;
	const QSize size(qMax(1, qRound(d->cursorImage.width() * scale * dpr)), qMax(1, qRound(d->cursorImage.height() * scale * dpr)));
	QPixmap pixmap = QPixmap::fromImage(d->cursorImage.scaled(size, Qt::IgnoreAspectRatio, Qt::SmoothTransformation));
	pixmap.setDevicePixelRatio(dpr);
	setCursor(QCursor(pixmap, qRound(d->hotX * scale), qRound(d->hotY * scale)));
}

void VmDisplay::setBroker(const QString &value) {
	if (m_broker == value) return;
	m_broker = value;
	emit brokerChanged();
	if (m_broker.isEmpty()) applyCursor();
	else setCursor(Qt::BlankCursor);
	stopSource();
	maybeStart();
}

void VmDisplay::stopSource() {
	setGrab(false);
	if (m_running) {
		m_running = false;
		emit runningChanged();
	}
	if (d->broker) d->broker->stop();
	d->display->stop();
	d->brokerFocused = false;
	d->brokerPointer = false;
}

void VmDisplay::maybeStart() {
	if (!window() || width() <= 0 || height() <= 0) return;
	if (m_running) return;
	if (m_broker.isEmpty() && m_qmp.isEmpty()) return;
	QScreen *screen = window()->screen();
	const QSize device = screen ? QSize(qRound(screen->size().width() * screen->devicePixelRatio()),
	                                    qRound(screen->size().height() * screen->devicePixelRatio()))
	                            : QSize(qRound(width() * window()->devicePixelRatio()),
	                                    qRound(height() * window()->devicePixelRatio()));
	if (device.width() <= 0 || device.height() <= 0) return;
	if (!m_broker.isEmpty()) {
		const qreal dpr = window()->devicePixelRatio();
		const QSize surface(qRound(width() * dpr), qRound(height() * dpr));
		if (surface.width() <= 0 || surface.height() <= 0) return;
		const int refresh = qRound((screen ? screen->refreshRate() : 60.0) * 1000.0);
		if (!d->broker->start(m_broker, surface.width(), surface.height(), refresh)) return;
		m_running = true;
		m_error.clear();
		emit errorChanged();
		emit runningChanged();
		updateBrokerFocus();
		return;
	}
	d->display->start(m_qmp, device.width(), device.height());
	m_running = true;
	emit runningChanged();
}

void VmDisplay::geometryChange(const QRectF &next, const QRectF &prev) {
	QQuickItem::geometryChange(next, prev);
	if (next.size().toSize() == prev.size().toSize()) return;
	maybeStart();
	if (m_running && !m_broker.isEmpty()) {
		const qreal dpr = window() ? window()->devicePixelRatio() : 1.0;
		d->broker->setSurfaceSize(qRound(width() * dpr), qRound(height() * dpr));
	} else if (m_running && window() && window()->visibility() == QWindow::FullScreen) {
		QScreen *screen = window()->screen();
		if (screen) d->display->setUiInfo(qRound(screen->size().width() * screen->devicePixelRatio()),
		                                  qRound(screen->size().height() * screen->devicePixelRatio()));
	}
	update();
}

void VmDisplay::itemChange(ItemChange change, const ItemChangeData &value) {
	QQuickItem::itemChange(change, value);
	if (change != ItemSceneChange) return;

	maybeStart();

	if (d->activeConnection) QObject::disconnect(d->activeConnection);

	QQuickWindow *win = value.window;
	if (!win) {
		d->inhibitor.inhibit(false);
		return;
	}

	d->activeConnection = connect(win, &QQuickWindow::activeChanged, this, [this]() {
		updateInhibitor();
		updateBrokerFocus();
	});
	updateInhibitor();
	updateBrokerFocus();
}

void VmDisplay::mousePressEvent(QMouseEvent *event) {
	d->pointerInside = insideImage(event->position());
	if (d->broker) d->broker->sendPointer(d->pointerInside);
	updateInhibitor();
	forceActiveFocus();
	sendMouse(event->position(), event->button(), true);
	event->accept();
}

void VmDisplay::mouseReleaseEvent(QMouseEvent *event) {
	sendMouse(event->position(), event->button(), false);
	event->accept();
}

void VmDisplay::mouseMoveEvent(QMouseEvent *event) {
	sendPosition(event->position());
	event->accept();
}

void VmDisplay::wheelEvent(QWheelEvent *event) {
	const int steps = event->angleDelta().y() / 120;
	const int horizontal = event->angleDelta().x() / 120;
	if (!m_broker.isEmpty() && d->broker) {
		d->broker->sendWheel(steps, horizontal);
		event->accept();
		return;
	}
	for (int i = 0; i < qAbs(steps); i++) d->display->wheel(steps > 0);
	event->accept();
}

void VmDisplay::sendPosition(const QPointF &pos) {
	if (!m_broker.isEmpty() && d->broker) {
		if (d->grabbed) return;
		const qreal dpr = window() ? window()->devicePixelRatio() : 1.0;
		const int w = qMax(1, qRound(width() * dpr));
		const int h = qMax(1, qRound(height() * dpr));
		QRectF dst = d->dstRect.isValid() && !d->dstRect.isEmpty() ? d->dstRect : boundingRect();
		if (dst.width() <= 0 || dst.height() <= 0 || !dst.contains(pos)) return;
		const qreal fx = (pos.x() - dst.x()) / dst.width();
		const qreal fy = (pos.y() - dst.y()) / dst.height();
		const int x = qBound(0, qRound(fx * (w - 1)), w - 1);
		const int y = qBound(0, qRound(fy * (h - 1)), h - 1);
		d->broker->sendAbs(x, y);
		return;
	}

	const int w = d->textureW > 0 ? d->textureW : qRound(width() * (window() ? window()->devicePixelRatio() : 1));
	const int h = d->textureH > 0 ? d->textureH : qRound(height() * (window() ? window()->devicePixelRatio() : 1));
	if (w <= 0 || h <= 0) return;

	QRectF dst = d->dstRect.isValid() && !d->dstRect.isEmpty() ? d->dstRect : boundingRect();
	if (!dst.contains(pos)) return;
	const qreal fx = (pos.x() - dst.x()) / dst.width();
	const qreal fy = (pos.y() - dst.y()) / dst.height();
	int x = qBound(0, qRound(fx * w), w - 1);
	int y = qBound(0, qRound(fy * h), h - 1);
	if (x == d->lastX && y == d->lastY) return;
	d->lastX = x;
	d->lastY = y;
	d->display->mouseAbs(x, y);
}

void VmDisplay::sendMouse(const QPointF &pos, Qt::MouseButton button, bool down) {
	sendPosition(pos);
	if (!m_broker.isEmpty() && d->broker) {
		int evdev = -1;
		switch (button) {
		case Qt::LeftButton: evdev = 0x110; break;
		case Qt::RightButton: evdev = 0x111; break;
		case Qt::MiddleButton: evdev = 0x112; break;
		default: return;
		}
		d->broker->sendButton(evdev, down);
		return;
	}
	int qbutton = 0;
	switch (button) {
	case Qt::LeftButton: qbutton = 0; break;
	case Qt::MiddleButton: qbutton = 1; break;
	case Qt::RightButton: qbutton = 2; break;
	default: return;
	}
	d->display->mouseButton(qbutton, down);
}

void VmDisplay::keyPressEvent(QKeyEvent *event) {
	if (event->isAutoRepeat()) {
		event->accept();
		return;
	}
	const int evdev = int(event->nativeScanCode()) - 8;
	if (!m_broker.isEmpty() && d->broker) {
		const Qt::KeyboardModifiers chord = Qt::ControlModifier | Qt::AltModifier;
		if (event->key() == Qt::Key_G && (event->modifiers() & chord) == chord) {
			d->swallowKey = evdev;
			setGrab(!d->grabbed);
			event->accept();
			return;
		}
		if (evdev > 0) d->broker->sendKey(evdev, true);
		event->accept();
		return;
	}
	const int qnum = qnumForEvdev(evdev);
	if (qnum >= 0) d->display->key(qnum, true);
	event->accept();
}

void VmDisplay::keyReleaseEvent(QKeyEvent *event) {
	if (event->isAutoRepeat()) {
		event->accept();
		return;
	}
	const int evdev = int(event->nativeScanCode()) - 8;
	if (!m_broker.isEmpty() && d->broker) {
		if (evdev == d->swallowKey) {
			d->swallowKey = -1;
			event->accept();
			return;
		}
		if (evdev > 0) d->broker->sendKey(evdev, false);
		event->accept();
		return;
	}
	const int qnum = qnumForEvdev(evdev);
	if (qnum >= 0) d->display->key(qnum, false);
	event->accept();
}

bool VmDisplay::insideImage(const QPointF &pos) const {
	if (d->dstRect.isValid() && !d->dstRect.isEmpty()) return d->dstRect.contains(pos);
	return boundingRect().contains(pos);
}

void VmDisplay::updateBrokerFocus() {
	if (m_broker.isEmpty() || !d->broker) return;
	if (!window() || !window()->isActive()) setGrab(false);
	d->broker->setWindowActive(window() && window()->isActive());
	const bool focused = window() && window()->isActive() && hasActiveFocus();
	if (focused == d->brokerFocused) return;
	d->brokerFocused = focused;
	d->broker->sendFocus(focused);
}

void VmDisplay::setGrab(bool on) {
	if (on == d->grabbed) return;
	if (on) {
		QQuickWindow *window = this->window();
		auto *application = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
		auto *wayland = window ? window->nativeInterface<QNativeInterface::Private::QWaylandWindow>() : nullptr;
		if (m_broker.isEmpty() || !d->broker || !application || !wayland || !window->isActive()) return;
		d->pointerLock.setSurface(application->display(), application->seat(), wayland->surface());
		if (!d->pointerLock.lock(true)) return;
		d->relX = 0;
		d->relY = 0;
		d->grabbed = true;
		d->broker->sendGrab(true);
	} else {
		d->pointerLock.lock(false);
		d->grabbed = false;
		if (d->broker) d->broker->sendGrab(false);
	}
	updateInhibitor();
	update();
}

void VmDisplay::updateInhibitor() {
	QQuickWindow *window = this->window();
	if (!window || !window->isActive() || (!d->pointerInside && !d->grabbed)) {
		d->inhibitor.inhibit(false);
		return;
	}

	auto *application = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
	auto *wayland = window->nativeInterface<QNativeInterface::Private::QWaylandWindow>();
	if (!application || !wayland) return;

	d->inhibitor.setSurface(application->display(), application->seat(), wayland->surface());
	d->inhibitor.inhibit(true);
	forceActiveFocus();
}

void VmDisplay::hoverEnterEvent(QHoverEvent *event) {
	d->pointerInside = insideImage(event->position());
	if (d->broker) d->broker->sendPointer(d->pointerInside);
	updateInhibitor();
	if (d->pointerInside) forceActiveFocus();
	QQuickItem::hoverEnterEvent(event);
}

void VmDisplay::hoverMoveEvent(QHoverEvent *event) {
	sendPosition(event->position());
	const bool inside = insideImage(event->position());
	if (inside != d->pointerInside) {
		d->pointerInside = inside;
		if (d->broker) d->broker->sendPointer(inside);
		updateInhibitor();
		if (inside) forceActiveFocus();
	}
	QQuickItem::hoverMoveEvent(event);
}

void VmDisplay::hoverLeaveEvent(QHoverEvent *event) {
	d->pointerInside = false;
	if (d->broker) d->broker->sendPointer(false);
	updateInhibitor();
	QQuickItem::hoverLeaveEvent(event);
}

QSGNode *VmDisplay::updatePaintNode(QSGNode *node, UpdatePaintNodeData *) {
	if (!window()) return nullptr;
	QOpenGLContext *context = QOpenGLContext::currentContext();
	if (!context) return nullptr;
	auto *egl = context->nativeInterface<QNativeInterface::QEGLContext>();
	if (!egl) return nullptr;
	d->eglDisplay = egl->display();
	loadEgl();
	if (!createImage || !imageTarget) return nullptr;

	QmpDisplay::Frame frame;
	const bool brokerFrame = !m_broker.isEmpty() && d->broker;
	if (brokerFrame) frame = d->broker->takeFrame();
	else frame = d->display->takeFrame();

	if (frame.fd >= 0) {
		if (d->mapBase) {
			munmap(d->mapBase, d->mapMapSize);
			d->mapBase = nullptr;
			d->mapData = nullptr;
			d->mapSize = 0;
			d->mapMapSize = 0;
		}
		d->mapMode = false;
		EGLImageKHR next = EGL_NO_IMAGE_KHR;
		if (d->eglDisplay != EGL_NO_DISPLAY) {
			EGLint attrs[] = {
				EGL_WIDTH, frame.w,
				EGL_HEIGHT, frame.h,
				EGL_LINUX_DRM_FOURCC_EXT, EGLint(frame.fourcc),
				EGL_DMA_BUF_PLANE0_FD_EXT, frame.fd,
				EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGLint(frame.offset),
				EGL_DMA_BUF_PLANE0_PITCH_EXT, EGLint(frame.stride),
				EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGLint(frame.modLo),
				EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGLint(frame.modHi),
				EGL_NONE,
			};
			next = createImage(d->eglDisplay, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
		}
		close(frame.fd);
		frame.fd = -1;
		if (next != EGL_NO_IMAGE_KHR) {
			GLuint texture = 0;
			glGenTextures(1, &texture);
			glBindTexture(GL_TEXTURE_2D, texture);
			while (glGetError() != GL_NO_ERROR) {}
			imageTarget(GL_TEXTURE_2D, next);
			if (glGetError() == GL_NO_ERROR) {
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
				if (d->texture) context->functions()->glDeleteTextures(1, &d->texture);
				if (d->image != EGL_NO_IMAGE_KHR) destroyImage(d->eglDisplay, d->image);
				d->image = next;
				d->texture = texture;
				d->textureW = frame.w;
				d->textureH = frame.h;
				d->y0top = frame.y0top;
				if (d->nodeTexture) {
					delete d->nodeTexture;
					d->nodeTexture = nullptr;
				}
			} else {
				qWarning() << "cannot import dma-buf" << Qt::hex << frame.fourcc << frame.modLo << frame.modHi;
				context->functions()->glDeleteTextures(1, &texture);
				destroyImage(d->eglDisplay, next);
			}
		}
	}
	if (brokerFrame) d->broker->frameConsumed();

	if (auto map = d->display->takeMap(); map.fd >= 0) {
		if (map.w > 0 && map.h > 0 && map.stride > 0) {
			if (d->mapBase) munmap(d->mapBase, d->mapMapSize);
			if (d->mapFd >= 0) close(d->mapFd);
			d->mapBase = nullptr;
			d->mapData = nullptr;
			d->mapFd = map.fd;
			d->mapW = map.w;
			d->mapH = map.h;
			d->mapStride = map.stride;
			d->mapOffset = map.offset;
			d->mapSize = size_t(map.stride) * map.h;
			d->mapMapSize = d->mapSize + size_t(map.offset);
			d->mapBase = mmap(nullptr, d->mapMapSize, PROT_READ, MAP_SHARED, map.fd, 0);
			if (d->mapBase == MAP_FAILED) {
				d->mapBase = nullptr;
				d->mapData = nullptr;
				d->mapSize = 0;
				d->mapMapSize = 0;
				close(map.fd);
				d->mapFd = -1;
			} else {
				d->mapData = static_cast<char *>(d->mapBase) + map.offset;
				close(map.fd);
				d->mapFd = -1;
				if (!d->texture) glGenTextures(1, &d->texture);
				glBindTexture(GL_TEXTURE_2D, d->texture);
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
				QByteArray rgba(static_cast<int>(d->mapW) * d->mapH * 4, Qt::Uninitialized);
				for (int row = 0; row < d->mapH; row++) {
					const unsigned char *src = static_cast<const unsigned char *>(d->mapData) + size_t(row) * d->mapStride;
					unsigned char *dst = reinterpret_cast<unsigned char *>(rgba.data()) + size_t(row) * d->mapW * 4;
					for (int col = 0; col < d->mapW; col++) {
						dst[col * 4 + 0] = src[col * 4 + 2];
						dst[col * 4 + 1] = src[col * 4 + 1];
						dst[col * 4 + 2] = src[col * 4 + 0];
						dst[col * 4 + 3] = src[col * 4 + 3];
					}
				}
				glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, d->mapW, d->mapH, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba.constData());
				d->textureW = d->mapW;
				d->textureH = d->mapH;
				d->y0top = true;
				d->mapMode = true;
				d->updatePending = false;
				if (d->nodeTexture) {
					delete d->nodeTexture;
					d->nodeTexture = nullptr;
				}
			}
		} else {
			close(map.fd);
		}
	}

	if (auto pixmap = d->display->takePixmap(); !pixmap.data.isEmpty() && pixmap.stride > 0) {
		if (!d->texture) {
			glGenTextures(1, &d->texture);
			glBindTexture(GL_TEXTURE_2D, d->texture);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		} else {
			glBindTexture(GL_TEXTURE_2D, d->texture);
		}
		glPixelStorei(GL_UNPACK_ROW_LENGTH, pixmap.stride / 4);
		if (!pixmap.update) {
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, pixmap.w, pixmap.h, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixmap.data.constData());
			d->textureW = pixmap.w;
			d->textureH = pixmap.h;
		} else if (d->textureW > 0 && d->textureH > 0) {
			glTexSubImage2D(GL_TEXTURE_2D, 0, pixmap.x, pixmap.y, pixmap.uw, pixmap.uh, GL_BGRA, GL_UNSIGNED_BYTE, pixmap.data.constData());
		}
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		d->mapMode = false;
		d->y0top = false;
		if (d->nodeTexture) {
			delete d->nodeTexture;
			d->nodeTexture = nullptr;
		}
	}

	if (d->mapMode && d->updatePending && d->texture && d->mapData) {
		const int x = qBound(0, d->updateX, d->mapW);
		const int y = qBound(0, d->updateY, d->mapH);
		const int w = qBound(0, d->updateX + d->updateW, d->mapW) - x;
		const int h = qBound(0, d->updateY + d->updateH, d->mapH) - y;
		if (w > 0 && h > 0) {
			glBindTexture(GL_TEXTURE_2D, d->texture);
			glPixelStorei(GL_UNPACK_ROW_LENGTH, d->mapStride / 4);
			glPixelStorei(GL_UNPACK_SKIP_PIXELS, x);
			glPixelStorei(GL_UNPACK_SKIP_ROWS, y);
			glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, w, h, GL_BGRA, GL_UNSIGNED_BYTE, d->mapData);
			glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
			glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
			glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		}
		d->updatePending = false;
	}

	auto *textureNode = static_cast<QSGSimpleTextureNode *>(node);
	if (!textureNode) textureNode = new QSGSimpleTextureNode;
	if (!d->texture || d->textureW <= 0 || d->textureH <= 0) {
		d->dstRect = QRectF();
		textureNode->setRect(boundingRect());
		return textureNode;
	}
	const QSizeF area = boundingRect().size();
	const qreal scale = qMin(area.width() / qreal(d->textureW), area.height() / qreal(d->textureH));
	const QSizeF fitted(qreal(d->textureW) * scale, qreal(d->textureH) * scale);
	d->dstRect = QRectF((area.width() - fitted.width()) / 2, (area.height() - fitted.height()) / 2, fitted.width(), fitted.height());
	if (!d->nodeTexture) {
		d->nodeTexture = QNativeInterface::QSGOpenGLTexture::fromNative(d->texture, window(), QSize(d->textureW, d->textureH), QQuickWindow::TextureHasAlphaChannel);
	}
	textureNode->setTexture(d->nodeTexture);
	textureNode->setRect(d->dstRect);
	if (qAbs(scale - d->cursorScale) > 0.001) {
		d->cursorScale = scale;
		QMetaObject::invokeMethod(this, &VmDisplay::applyCursor, Qt::QueuedConnection);
	}
	textureNode->setTextureCoordinatesTransform(d->y0top ? QSGSimpleTextureNode::MirrorVertically : QSGSimpleTextureNode::NoTransform);
	textureNode->markDirty(QSGNode::DirtyMaterial);

	return textureNode;
}
