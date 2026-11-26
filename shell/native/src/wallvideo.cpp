#include "wallvideo.h"

#include <QFileInfo>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <algorithm>

extern "C" {
#include "settle.h"
#include "video.h"
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

namespace {

constexpr int queueDepth = 3;

class FrameNode : public QSGSimpleTextureNode {
public:
	~FrameNode() override { delete texture(); }

	void swap(QSGTexture *next) {
		QSGTexture *old = texture();
		setTexture(next);
		delete old;
	}
};

}

WallDecoder::WallDecoder(const QString &path, double still, double settle, double curve)
	: m_path(path), m_still(still), m_travel(settle / curve) {}

WallDecoder::~WallDecoder() {
	stop();
	wait();
}

void WallDecoder::stop() {
	m_stop = true;
	QMutexLocker lock(&m_mutex);
	m_room.wakeAll();
}

void WallDecoder::setTarget(int width, int height) {
	m_width = width;
	m_height = height;
}

void WallDecoder::setClock(double t) {
	m_clock = t;
}

bool WallDecoder::take(double t, Frame *out) {
	QMutexLocker lock(&m_mutex);
	bool got = false;
	while (!m_queue.empty() && (t < 0 || m_queue.front().t <= t + 1e-4)) {
		*out = std::move(m_queue.front());
		m_queue.pop_front();
		got = true;
		if (t < 0) break;
	}
	if (got) m_room.wakeAll();
	return got;
}

bool WallDecoder::drained() {
	QMutexLocker lock(&m_mutex);
	return m_queue.empty();
}

void WallDecoder::run() {
	const QByteArray path = m_path.toLocal8Bit();
	vdec *vd = vd_open(path.constData(), 1);
	if (!vd) {
		m_done = true;
		emit failed();
		return;
	}

	const double duration = vd_duration(vd);
	const double fps = vd_fps(vd) > 0 ? vd_fps(vd) : 30;
	const double end = wr_settle_target(0, m_still, duration, m_travel);
	m_end = end;
	m_opened = true;

	AVFrame *sw = av_frame_alloc();
	SwsContext *sws = nullptr;
	int loops = 0;
	int rewinds = 0;

	while (!m_stop) {
		AVFrame *frame = nullptr;
		double pts = 0;
		const int result = vd_next(vd, &frame, &pts);
		if (result == 1 && duration > 0 && rewinds < 3) {
			vd_seek(vd, 0);
			loops++;
			rewinds++;
			continue;
		}
		if (result != 0) break;
		rewinds = 0;

		const double t = loops * duration + pts;
		if (t > end + 1e-4) break;
		if (t < m_clock.load() - 1.0 / fps && t < end - 0.5) continue;

		AVFrame *src = frame;
		if (frame->format == AV_PIX_FMT_VAAPI) {
			av_frame_unref(sw);
			if (av_hwframe_transfer_data(sw, frame, 0) < 0) continue;
			src = sw;
		}

		int width = m_width.load();
		int height = m_height.load();
		if (width <= 0 || height <= 0) {
			width = src->width;
			height = src->height;
		}
		const double scale = std::min(1.0, std::max(width / double(src->width), height / double(src->height)));
		const int w = std::max(2, int(src->width * scale));
		const int h = std::max(2, int(src->height * scale));

		// ponytail: frames are scaled to RGB on the CPU, one thread, ~10 ms at 1440p; upgrade path is the daemon's zero-copy EGL import.
		sws = sws_getCachedContext(sws, src->width, src->height, AVPixelFormat(src->format), w, h, AV_PIX_FMT_RGB0, SWS_BILINEAR, nullptr, nullptr, nullptr);
		if (!sws) break;
		QImage image(w, h, QImage::Format_RGBX8888);
		uint8_t *planes[4] = { image.bits(), nullptr, nullptr, nullptr };
		int strides[4] = { int(image.bytesPerLine()), 0, 0, 0 };
		sws_scale(sws, src->data, src->linesize, 0, src->height, planes, strides);

		QMutexLocker lock(&m_mutex);
		while (int(m_queue.size()) >= queueDepth && !m_stop) m_room.wait(&m_mutex);
		if (m_stop) break;
		m_queue.push_back({ t, std::move(image) });
	}

	sws_freeContext(sws);
	av_frame_free(&sw);
	vd_close(vd);
	m_done = true;
}

WallVideo::WallVideo(QQuickItem *parent) : QQuickItem(parent) {
	setFlag(ItemHasContents, true);
}

WallVideo::~WallVideo() {
	halt();
}

void WallVideo::setSource(const QString &value) {
	QString path = value.startsWith(QStringLiteral("file://")) ? value.mid(7) : value;
	if (path == m_source) return;
	m_source = path;
	emit sourceChanged();
	if (isComponentComplete()) queueRestart();
}

void WallVideo::setStill(double value) {
	if (value == m_still) return;
	m_still = value;
	emit stillChanged();
}

void WallVideo::setSettleMs(int value) {
	value = std::clamp(value, 100, 10000);
	if (value == m_settleMs) return;
	m_settleMs = value;
	emit settleMsChanged();
}

void WallVideo::setCurve(double value) {
	value = std::clamp(value, 1.0, 8.0);
	if (value == m_curve) return;
	m_curve = value;
	emit curveChanged();
}

void WallVideo::componentComplete() {
	QQuickItem::componentComplete();
	queueRestart();
}

void WallVideo::queueRestart() {
	if (m_restartQueued) return;
	m_restartQueued = true;
	QMetaObject::invokeMethod(this, [this]() {
		m_restartQueued = false;
		restart();
	}, Qt::QueuedConnection);
}

void WallVideo::restart() {
	halt();
	m_clock.invalidate();
	m_image = QImage();
	m_dirty = true;
	setReady(false);
	setSettled(false);
	setFailed(false);
	update();
	if (m_source.isEmpty() || !QFileInfo::exists(m_source)) {
		setFailed(!m_source.isEmpty());
		return;
	}

	m_decoder = new WallDecoder(m_source, m_still, m_settleMs / 1000.0, m_curve);
	connect(m_decoder, &WallDecoder::failed, this, [this]() { setFailed(true); }, Qt::QueuedConnection);
	pushTarget();
	m_decoder->start();
}

void WallVideo::halt() {
	if (!m_decoder) return;
	m_decoder->stop();
	m_decoder->wait();
	delete m_decoder;
	m_decoder = nullptr;
}

void WallVideo::pushTarget() {
	if (!m_decoder) return;
	const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1;
	m_decoder->setTarget(int(width() * dpr), int(height() * dpr));
}

void WallVideo::tick() {
	if (!m_decoder || m_settled) return;
	if (!m_decoder->opened()) {
		if (m_decoder->done()) setFailed(true);
		else update();
		return;
	}

	const double end = m_decoder->end();
	const double settle = m_settleMs / 1000.0;
	const double t = m_clock.isValid() ? wr_settle_time(m_clock.nsecsElapsed() / 1e9, end, settle, m_curve) : -1;
	if (t >= 0) m_decoder->setClock(t);

	WallDecoder::Frame frame;
	if (m_decoder->take(t, &frame)) {
		m_image = std::move(frame.image);
		m_dirty = true;
		if (!m_clock.isValid()) m_clock.start();
		setReady(true);
	}

	if (m_decoder->done() && m_decoder->drained() && (t >= end || !m_ready)) {
		halt();
		if (m_ready) setSettled(true);
		else setFailed(true);
	}
	update();
}

QSGNode *WallVideo::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
	auto *node = static_cast<FrameNode *>(old);
	if (m_image.isNull()) {
		delete node;
		return nullptr;
	}
	if (!node) {
		node = new FrameNode;
		node->setFiltering(QSGTexture::Linear);
		m_dirty = true;
	}
	if (m_dirty) {
		node->swap(window()->createTextureFromImage(m_image));
		m_dirty = false;
	}

	const QSizeF box = size();
	const QSizeF image = m_image.size();
	const qreal scale = std::max(box.width() / image.width(), box.height() / image.height());
	const QSizeF crop(box.width() / scale, box.height() / scale);
	node->setRect(boundingRect());
	node->setSourceRect(QRectF(QPointF((image.width() - crop.width()) / 2, (image.height() - crop.height()) / 2), crop));
	return node;
}

void WallVideo::geometryChange(const QRectF &next, const QRectF &prev) {
	QQuickItem::geometryChange(next, prev);
	pushTarget();
	update();
}

void WallVideo::itemChange(ItemChange change, const ItemChangeData &value) {
	QQuickItem::itemChange(change, value);
	if (change != ItemSceneChange) return;
	disconnect(m_frames);
	if (!value.window) return;
	m_frames = connect(value.window, &QQuickWindow::afterAnimating, this, &WallVideo::tick);
	pushTarget();
	update();
}

void WallVideo::setReady(bool on) {
	if (on == m_ready) return;
	m_ready = on;
	emit readyChanged();
}

void WallVideo::setSettled(bool on) {
	if (on == m_settled) return;
	m_settled = on;
	emit settledChanged();
}

void WallVideo::setFailed(bool on) {
	if (on == m_failed) return;
	m_failed = on;
	emit failedChanged();
}
