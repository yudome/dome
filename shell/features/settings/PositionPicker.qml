pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui

Rectangle {
	id: root

	property string value: ""

	readonly property var cells: ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"]

	signal picked(string value)

	implicitWidth: Config.appControlWidth / 2.25
	implicitHeight: implicitWidth * 0.6
	width: implicitWidth
	height: implicitHeight
	radius: Config.appControlRadius
	color: Config.surfaceHover

	Repeater {
		model: root.cells

		delegate: Item {
			id: cell

			required property string modelData
			required property int index

			readonly property bool chosen: root.value === cell.modelData

			x: (cell.index % 3) * root.width / 3
			y: Math.floor(cell.index / 3) * root.height / 2
			width: root.width / 3
			height: root.height / 2
			activeFocusOnTab: true

			Accessible.role: Accessible.RadioButton
			Accessible.name: cell.modelData
			Accessible.checked: cell.chosen
			Accessible.onPressAction: root.picked(cell.modelData)

			Keys.onSpacePressed: root.picked(cell.modelData)

			Rectangle {
				anchors.centerIn: parent
				width: cell.chosen ? Config.appChipHeight - Config.gapsIn : Config.stepBarDot * 2
				height: cell.chosen ? Config.appCaptionSize + Config.gapsIn / 2 : Config.stepBarDot * 2
				radius: Config.stepBarGlyphRadius
				color: cell.chosen ? Config.foreground : (spotHover.containsMouse ? Config.muted : Config.dim)

				Behavior on width {
					NumberAnimation {
						duration: Config.toggleMs
						easing.type: Easing.OutCubic
					}
				}
			}

			FocusRing {}

			MouseArea {
				id: spotHover

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.picked(cell.modelData)
			}
		}
	}
}
