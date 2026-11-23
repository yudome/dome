pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.services

Column {
	id: root

	property var entries: null
	property var dismiss: null
	property string trayKey: ""
	property int openIndex: -1
	property real indent: 0
	property var levelComponent: null
	property real minWidth: Config.trayMenuWidth

	readonly property real rowWidth: {
		let widest = root.minWidth;
		for (let i = 0; i < root.children.length; i++) {
			const natural = root.children[i].natural;
			if (natural !== undefined)
				widest = Math.max(widest, natural);
		}
		return widest;
	}

	Component.onCompleted: {
		if (root.levelComponent === null)
			root.levelComponent = Qt.createComponent(Qt.resolvedUrl("MenuLevel.qml"));
	}

	spacing: 0

	Repeater {
		model: root.entries

		delegate: Column {
			id: row

			required property var modelData
			required property int index

			readonly property var entry: modelData
			readonly property bool submenu: modelData.hasChildren === true
			readonly property bool separator: modelData.isSeparator === true
			readonly property bool checked: !row.separator && modelData.checkState === 2
			readonly property real natural: row.separator ? 0 : menuRow.implicitWidth

			spacing: 0
			visible: row.entry.visible !== false

			Separator {
				visible: row.separator
				width: root.rowWidth
				color: Config.rule
			}

			MenuRow {
				id: menuRow

				visible: !row.separator
				width: root.rowWidth
				height: Config.trayMenuRowHeight
				indent: root.indent
				enabled: row.entry.enabled === true
				text: row.entry.text || ""
				source: enabled && row.entry.icon ? row.entry.icon : ""
				current: row.checked
				submenu: row.submenu
				selected: row.submenu && root.openIndex === row.index

				onHoveredChanged: {
					if (hovered && enabled)
						root.openIndex = row.submenu ? row.index : -1;
				}

				onClicked: {
					if (row.submenu) {
						root.openIndex = root.openIndex === row.index ? -1 : row.index;
						return;
					}

					Yudae.cmd("tray", { key: root.trayKey, menu: row.entry.id });

					if (root.dismiss)
						root.dismiss();
				}
			}

			Loader {
				id: subLoader

				height: subLoader.item ? subLoader.item.implicitHeight : 0
				active: row.submenu && row.entry.isSeparator !== true && row.entry.enabled === true && root.openIndex === row.index
				sourceComponent: root.levelComponent

				onLoaded: {
					item.entries = row.entry.children;
					item.trayKey = root.trayKey;
					item.dismiss = root.dismiss;
					item.indent = root.indent + Config.fontSize;
					item.levelComponent = root.levelComponent;
					item.minWidth = Qt.binding(function () { return root.rowWidth; });
				}
			}
		}
	}
}
