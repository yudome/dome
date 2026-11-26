#include "plugin.h"
#include "vmdisplay.h"
#include "wallvideo.h"

void YudaeNativePlugin::registerTypes(const char *uri) {
	qmlRegisterType<VmDisplay>(uri, 1, 0, "VmDisplay");
	qmlRegisterType<WallVideo>(uri, 1, 0, "WallVideo");
}
