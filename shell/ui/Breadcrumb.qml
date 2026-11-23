pragma ComponentBehavior: Bound

import QtQuick
import qs

Item {
	id: root

	property var segments: []

	signal picked(var value)

	implicitHeight: Config.appChipHeight
	clip: true

	Row {
		id: row

		x: Math.min(0, root.width - row.width)
		anchors.verticalCenter: parent.verticalCenter
		spacing: Config.gapsIn

		Repeater {
			model: root.segments

			delegate: Row {
				id: crumb

				required property var modelData
				required property int index

				readonly property bool last: crumb.index === root.segments.length - 1

				spacing: Config.gapsIn

				Icon {
					anchors.verticalCenter: parent.verticalCenter
					visible: crumb.index > 0
					width: Config.appCaptionSize
					height: Config.appCaptionSize
					size: Config.appCaptionSize
					name: "right"
					ink: Config.dim
				}

				Label {
					id: label

					anchors.verticalCenter: parent.verticalCenter
					anchors.verticalCenterOffset: label.capOffset
					ink: crumb.last || hit.containsMouse ? Config.foreground : Config.muted
					text: crumb.modelData.label

					MouseArea {
						id: hit

						anchors.fill: parent
						hoverEnabled: !crumb.last
						enabled: !crumb.last
						cursorShape: Qt.PointingHandCursor
						onClicked: root.picked(crumb.modelData.value)
					}
				}
			}
		}
	}
}
