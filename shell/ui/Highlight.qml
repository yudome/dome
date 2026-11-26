import QtQuick
import qs

Rectangle {
	id: root

	property bool active: true
	property bool fillParent: true

	readonly property color ink: Config.foreground

	anchors.fill: root.fillParent ? parent : undefined
	radius: Config.appControlRadius
	color: Config.surfaceHover
	opacity: root.active ? 1 : 0

	Fade on opacity {
		duration: Math.round(Config.toggleMs / 2)
	}
}
