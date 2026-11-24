pragma ComponentBehavior: Bound

import QtQuick
import qs

Rectangle {
	id: root

	property var entries: []
	property var current: undefined
	property real menuWidth: Config.appControlWidth * 0.75
	property int armed: -1

	signal picked(var entry)

	implicitWidth: Math.max(root.menuWidth, column.implicitWidth + Config.gapsIn * 2)
	implicitHeight: column.implicitHeight + Config.gapsIn * 2
	radius: Config.appControlRadius
	color: Config.surface
	border.width: Config.popupBorderWidth
	border.color: Config.rule

	onVisibleChanged: root.armed = -1
	onEntriesChanged: root.armed = -1

	function activate(index, entry) {
		if (entry.confirm === true && root.armed !== index) {
			root.armed = index;
			disarm.restart();
			return;
		}
		root.armed = -1;
		root.picked(entry);
	}

	Timer {
		id: disarm

		interval: Config.confirmMs
		onTriggered: root.armed = -1
	}

	Column {
		id: column

		x: Config.gapsIn
		y: Config.gapsIn
		width: root.width - Config.gapsIn * 2

		Repeater {
			model: root.entries

			delegate: MenuRow {
				required property var modelData
				required property int index

				width: column.width
				text: root.armed === index && modelData.confirmLabel ? modelData.confirmLabel : modelData.label !== undefined ? modelData.label : String(modelData)
				icon: modelData.icon || ""
				danger: modelData.danger === true
				enabled: modelData.enabled !== false
				current: root.current !== undefined && (modelData.value !== undefined ? modelData.value : modelData) === root.current
				armed: root.armed === index
				onClicked: root.activate(index, modelData)
			}
		}

		Hint {
			x: Config.appControlRadius
			shown: root.armed >= 0 && root.armed < root.entries.length && (root.entries[root.armed].hint || "") !== ""
			inkMuted: Config.red
			text: root.armed >= 0 && root.armed < root.entries.length ? root.entries[root.armed].hint || "" : ""
		}
	}
}
