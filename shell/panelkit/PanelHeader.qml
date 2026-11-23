import QtQuick
import qs
import qs.ui

Item {
	id: root

	property string title: ""
	property string value: ""
	property color ink: Config.foreground
	property color valueInk: Config.foreground

	default property alias trailing: tail.data

	width: parent ? parent.width : 0
	implicitHeight: Math.max(titleLabel.implicitHeight, tail.implicitHeight)

	Label {
		id: titleLabel

		anchors.left: parent.left
		anchors.right: tail.left
		anchors.rightMargin: Config.gapsIn * 2
		anchors.verticalCenter: parent.verticalCenter
		ink: root.ink
		text: root.title
	}

	Row {
		id: tail

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		spacing: Config.gapsIn * 2

		Label {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.value !== ""
			role: "value"
			ink: root.valueInk
			text: root.value
		}
	}
}
