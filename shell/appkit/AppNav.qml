pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui

Item {
	id: root

	property var model: []
	property var current: undefined
	property string labelRole: "name"
	property string iconRole: "glyph"
	property string valueRole: "name"

	signal picked(var value)

	anchors.fill: parent

	function valueOf(entry) {
		return entry[root.valueRole];
	}

	Flickable {
		id: flick

		x: Metrics.gapSmall * 3
		width: parent.width - x * 2
		height: parent.height
		contentHeight: column.height + Metrics.gap
		boundsBehavior: Flickable.StopAtBounds
		acceptedButtons: Qt.NoButton
		clip: true

		Column {
			id: column

			width: flick.width
			spacing: Metrics.gapSmall / 2

			Repeater {
				model: root.model

				delegate: NavItem {
					required property var modelData

					width: column.width
					text: modelData[root.labelRole]
					icon: modelData[root.iconRole] || ""
					selected: root.current !== undefined && root.valueOf(modelData) === root.current
					onClicked: root.picked(root.valueOf(modelData))
				}
			}
		}
	}

	AppScroll {
		anchors.fill: parent
		view: flick
	}
}
