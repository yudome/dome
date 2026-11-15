#pragma once

#include "qmp.h"

#include <QObject>
#include <QString>
#include <cstdint>
#include <memory>

class BrokerDisplay : public QObject {
	Q_OBJECT

public:
	explicit BrokerDisplay(QObject *parent = nullptr);
	~BrokerDisplay() override;

	bool start(const QString &socketPath, int width, int height, int refreshMilliHz = 0);
	void stop();
	bool running() const;
	bool attached() const;
	void setSurfaceSize(int width, int height);
	void frameConsumed();
	void sendKey(int evdev, bool down);
	void sendButton(int evdev, bool down);
	void sendAbs(int x, int y);
	void sendWheel(int vertical, int horizontal);
	void sendFocus(bool focused);
	void setWindowActive(bool active);
	void sendPointer(bool inside);
	QmpDisplay::Frame takeFrame();

signals:
	void frameReady();
	void failed(const QString &message);

private:
	struct Impl;
	std::unique_ptr<Impl> d;
};
