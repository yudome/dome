#pragma once

#include <QtQml/qqmlregistration.h>
#include <QImage>
#include <QMutex>
#include <QQuickItem>
#include <QString>
#include <QThread>
#include <QWaitCondition>
#include <QElapsedTimer>
#include <atomic>
#include <deque>

class WallDecoder : public QThread {
	Q_OBJECT

public:
	struct Frame {
		double t;
		QImage image;
	};

	WallDecoder(const QString &path, double still, double settle, double curve);
	~WallDecoder() override;

	void stop();
	void setTarget(int width, int height);
	void setClock(double t);
	bool take(double t, Frame *out);
	bool drained();
	double end() const { return m_end.load(); }
	bool opened() const { return m_opened.load(); }
	bool done() const { return m_done.load(); }

signals:
	void failed();

protected:
	void run() override;

private:
	QString m_path;
	double m_still;
	double m_travel;
	QMutex m_mutex;
	QWaitCondition m_room;
	std::deque<Frame> m_queue;
	std::atomic<bool> m_stop { false };
	std::atomic<bool> m_done { false };
	std::atomic<bool> m_opened { false };
	std::atomic<double> m_end { -1 };
	std::atomic<double> m_clock { 0 };
	std::atomic<int> m_width { 0 };
	std::atomic<int> m_height { 0 };
};

class WallVideo : public QQuickItem {
	Q_OBJECT
	QML_ELEMENT
	Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
	Q_PROPERTY(double still READ still WRITE setStill NOTIFY stillChanged)
	Q_PROPERTY(int settleMs READ settleMs WRITE setSettleMs NOTIFY settleMsChanged)
	Q_PROPERTY(double curve READ curve WRITE setCurve NOTIFY curveChanged)
	Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
	Q_PROPERTY(bool settled READ settled NOTIFY settledChanged)
	Q_PROPERTY(bool failed READ failed NOTIFY failedChanged)

public:
	explicit WallVideo(QQuickItem *parent = nullptr);
	~WallVideo() override;

	QString source() const { return m_source; }
	void setSource(const QString &value);
	double still() const { return m_still; }
	void setStill(double value);
	int settleMs() const { return m_settleMs; }
	void setSettleMs(int value);
	double curve() const { return m_curve; }
	void setCurve(double value);
	bool ready() const { return m_ready; }
	bool settled() const { return m_settled; }
	bool failed() const { return m_failed; }

	Q_INVOKABLE void restart();

	QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *) override;

signals:
	void sourceChanged();
	void stillChanged();
	void settleMsChanged();
	void curveChanged();
	void readyChanged();
	void settledChanged();
	void failedChanged();

protected:
	void geometryChange(const QRectF &next, const QRectF &prev) override;
	void itemChange(ItemChange change, const ItemChangeData &value) override;
	void componentComplete() override;

private:
	void tick();
	void queueRestart();
	void halt();
	void pushTarget();
	void setReady(bool on);
	void setSettled(bool on);
	void setFailed(bool on);

	QString m_source;
	double m_still = 0;
	int m_settleMs = 1200;
	double m_curve = 3;
	bool m_ready = false;
	bool m_settled = false;
	bool m_failed = false;
	bool m_dirty = false;
	bool m_restartQueued = false;
	WallDecoder *m_decoder = nullptr;
	QElapsedTimer m_clock;
	QImage m_image;
	QMetaObject::Connection m_frames;
};
