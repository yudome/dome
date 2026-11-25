#include "qmp.h"

#include <QCoreApplication>
#include <QTimer>

#include <unistd.h>

int main(int argc, char **argv) {
	QCoreApplication app(argc, argv);

	QString qmp;
	int width = 1536;
	int height = 864;
	int fps = 0;

	for (int i = 1; i < argc; i++) {
		const QString arg = QString::fromLocal8Bit(argv[i]);
		if (arg == "--qmp" && i + 1 < argc) qmp = QString::fromLocal8Bit(argv[++i]);
		else if (arg == "--width" && i + 1 < argc) width = QString::fromLocal8Bit(argv[++i]).toInt();
		else if (arg == "--height" && i + 1 < argc) height = QString::fromLocal8Bit(argv[++i]).toInt();
		else if (arg == "--fps" && i + 1 < argc) fps = QString::fromLocal8Bit(argv[++i]).toInt();
	}

	if (qmp.isEmpty()) return 2;
	if (fps < 0) fps = 0;
	if (fps > 240) fps = 240;

	QmpDisplay display;
	display.start(qmp, width, height);

	QTimer timer;
	timer.setInterval(fps > 0 ? 1000 / fps : 16);
	QObject::connect(&timer, &QTimer::timeout, [&display]() {
		auto frame = display.takeFrame();
		if (frame.fd >= 0) close(frame.fd);
		auto map = display.takeMap();
		if (map.fd >= 0) close(map.fd);
	});
	timer.start();

	return app.exec();
}
