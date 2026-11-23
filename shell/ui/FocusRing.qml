import QtQuick
import qs

Rectangle {
	id: root

	property Item target: parent
	property bool shown: root.target !== null && root.target.activeFocus

	anchors.fill: root.target
	anchors.margins: -Config.popupBorderWidth * 2
	radius: Config.appControlRadius
	color: "transparent"
	border.width: Config.popupBorderWidth
	border.color: Config.foreground
	visible: root.shown
}
