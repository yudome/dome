import QtQuick
import qs
import qs.ui

Item {
	id: root

	property string title: ""
	property color ink: Config.foreground
	property real bleed: 0

	implicitHeight: Config.rowHeight

	Rectangle {
		anchors.fill: parent
		anchors.leftMargin: -root.bleed
		anchors.rightMargin: -root.bleed
		color: Config.surfaceRaised
	}

	Label {
		anchors.left: parent.left
		anchors.leftMargin: Config.gapsIn
		anchors.right: parent.right
		anchors.rightMargin: Config.gapsIn
		anchors.verticalCenter: parent.verticalCenter
		horizontalAlignment: Text.AlignHCenter
		ink: root.ink
		text: root.title
	}
}
