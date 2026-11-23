import QtQuick
import qs

Rectangle {
	id: root

	property string text: ""
	property string tone: "plain"

	readonly property color ink: root.tone === "danger" ? Config.red : root.tone === "warning" ? Config.yellow : Config.muted

	implicitWidth: label.implicitWidth + Config.gapsIn * 3
	implicitHeight: label.implicitHeight + Config.gapsIn / 2
	radius: height / 2
	color: "transparent"
	border.width: Config.popupBorderWidth
	border.color: root.ink

	Label {
		id: label

		anchors.centerIn: parent
		role: "caption"
		ink: root.ink
		text: root.text
	}
}
