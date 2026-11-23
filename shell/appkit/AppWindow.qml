import QtQuick
import Quickshell
import qs

FloatingWindow {
	id: root

	default property alias content: body.data

	signal appClosed()

	property string appTitle: ""
	property string preset: "medium"

	readonly property size presetSize: root.preset === "small" ? Qt.size(Config.appSmallWidth, Config.appSmallHeight) : root.preset === "large" ? Qt.size(Config.appLargeWidth, Config.appLargeHeight) : Qt.size(Config.appMediumWidth, Config.appMediumHeight)

	title: root.appTitle
	minimumSize: Qt.size(Config.appFloorWidth, Config.appFloorHeight)
	color: Config.surface
	visible: true
	implicitWidth: root.presetSize.width
	implicitHeight: root.presetSize.height

	onClosed: root.appClosed()

	Connections {
		target: Quickshell

		function onLastWindowClosed() {
			Qt.quit();
		}
	}

	Shortcut {
		sequence: "F11"
		onActivated: root.fullscreen = !root.fullscreen
	}

	Item {
		id: body

		anchors.fill: parent
		focus: true
	}
}
