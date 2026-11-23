pragma ComponentBehavior: Bound

import QtQuick
import qs

Row {
	id: root

	property var model: []
	property var current: undefined

	signal picked(var value)

	spacing: Config.appGap
	height: Config.appChipHeight

	function valueOf(entry) {
		return typeof entry === "object" && entry !== null && entry.value !== undefined ? entry.value : entry;
	}

	function labelOf(entry) {
		return typeof entry === "object" && entry !== null && entry.label !== undefined ? entry.label : String(entry);
	}

	Repeater {
		model: root.model

		delegate: Item {
			id: tab

			required property var modelData

			readonly property bool selected: root.valueOf(tab.modelData) === root.current

			width: label.implicitWidth
			height: root.height
			activeFocusOnTab: true

			Accessible.role: Accessible.PageTab
			Accessible.name: label.text
			Accessible.selected: tab.selected
			Accessible.onPressAction: root.picked(root.valueOf(tab.modelData))

			Keys.onSpacePressed: root.picked(root.valueOf(tab.modelData))
			Keys.onReturnPressed: root.picked(root.valueOf(tab.modelData))

			Label {
				id: label

				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: label.capOffset
				ink: tab.selected || hit.containsMouse ? Config.foreground : Config.muted
				text: root.labelOf(tab.modelData)
			}

			Rectangle {
				anchors.bottom: parent.bottom
				width: parent.width
				height: Config.popupBorderWidth * 2
				radius: height / 2
				color: Config.foreground
				visible: tab.selected
			}

			FocusRing {}

			MouseArea {
				id: hit

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.picked(root.valueOf(tab.modelData))
			}
		}
	}
}
