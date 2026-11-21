pragma Singleton

import QtQuick
import Quickshell
import qs
import qs.services

QtObject {
	id: root

	readonly property int fontSize: Config.fontSize
	readonly property int iconSize: Config.iconSize
}
