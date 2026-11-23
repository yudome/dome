import QtQuick
import qs

Item {
	id: root

	property string label: ""
	property string note: ""
	property bool pending: false
	property bool last: false
	property real controlWidth: Math.min(Config.appControlWidth, root.width / 2)
	property real controlHeight: Config.appChipHeight

	default property alias control: slot.data

	implicitHeight: Math.max(Config.appRowHeight, labels.height + Config.appGap, root.controlHeight + Config.appGap)

	Separator {
		visible: !root.last
		anchors.bottom: parent.bottom
		width: parent.width
		color: Config.rule
	}

	Column {
		id: labels

		anchors.left: parent.left
		anchors.right: slot.left
		anchors.rightMargin: Config.appGap
		anchors.verticalCenter: parent.verticalCenter
		spacing: Config.gapsIn

		Item {
			width: parent.width
			height: name.height

			Label {
				id: name

				width: Math.min(implicitWidth, parent.width - dot.width - Config.gapsIn * 2)
				text: root.label
			}

			Rectangle {
				id: dot

				anchors.left: name.right
				anchors.leftMargin: Config.gapsIn * 2
				anchors.verticalCenter: name.verticalCenter
				anchors.verticalCenterOffset: name.capOffset
				width: Config.stepBarDot * 2
				height: width
				radius: width / 2
				color: Config.yellow
				visible: root.pending
			}
		}

		Label {
			width: parent.width
			visible: text !== ""
			role: "caption"
			wrapMode: Text.WordWrap
			maximumLineCount: 2
			text: root.note
		}
	}

	Item {
		id: slot

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: root.controlWidth
		height: root.controlHeight
	}
}
