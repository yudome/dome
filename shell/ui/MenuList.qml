import QtQuick
import QtQuick.Controls as QQC
import qs
import qs.ui

Item {
	id: root

	property var entries: []
	property var current: undefined
	property real menuWidth: Config.appControlWidth * 0.75
	property int armed: -1
	property int openIndex: -1
	property bool overlay: false
	property bool framed: true
	property bool live: true
	property var anchorWindow: null
	property var panelComponent: null

	readonly property var entry: root.openIndex >= 0 && root.entries ? root.entries[root.openIndex] : null
	readonly property bool submenuOpen: root.live && root.visible && root.entry !== null && root.entry !== undefined && root.entry.hasChildren === true

	readonly property real rowWidth: {
		let widest = root.menuWidth;
		for (let i = 0; i < repeater.count; i++) {
			const item = repeater.itemAt(i);
			if (item && item.visible)
				widest = Math.max(widest, item.implicitWidth);
		}
		return widest;
	}
	readonly property real padX: root.framed ? Config.gapsIn : 0
	readonly property real padY: Config.gapsIn
	readonly property real separatorHeight: Config.trayMenuSeparator + Config.gapsIn * 2

	signal picked(var entry)

	implicitWidth: root.rowWidth + root.padX * 2
	implicitHeight: column.implicitHeight + root.padY * 2
	width: implicitWidth
	height: implicitHeight

	Component.onCompleted: {
		if (root.panelComponent === null)
			root.panelComponent = Qt.createComponent(Qt.resolvedUrl("MenuList.qml"));
	}

	function rowAt(index) {
		return repeater.itemAt(index);
	}

	function attach(item) {
		item.entries = Qt.binding(function () { return root.entry ? root.entry.children || [] : []; });
		item.overlay = root.overlay;
		item.anchorWindow = root.anchorWindow;
		item.menuWidth = root.menuWidth;
		item.live = Qt.binding(function () { return root.submenuOpen; });
		item.picked.connect(function (picked) { root.picked(picked); });
	}

	function activate(index, entry) {
		if (entry.hasChildren === true) {
			root.openIndex = root.openIndex === index ? -1 : index;
			return;
		}

		if (entry.confirm === true && root.armed !== index) {
			root.armed = index;
			disarm.restart();
			return;
		}
		root.armed = -1;
		root.picked(entry);
	}

	onVisibleChanged: root.armed = -1
	onEntriesChanged: {
		root.armed = -1;
		root.openIndex = -1;
	}

	Timer {
		id: disarm

		interval: Config.confirmMs
		onTriggered: root.armed = -1
	}

	Rectangle {
		visible: root.framed
		width: root.width
		height: root.height
		radius: Config.appControlRadius
		color: Config.surface
		border.width: Config.popupBorderWidth
		border.color: Config.rule
	}

	Column {
		id: column

		x: root.padX
		y: root.padY
		width: root.rowWidth

		Repeater {
			id: repeater

			model: root.entries

			delegate: Item {
				id: rowItem

				required property var modelData
				required property int index

				readonly property bool separator: modelData.isSeparator === true
				readonly property bool submenu: !rowItem.separator && modelData.hasChildren === true

				visible: modelData.visible !== false
				width: root.rowWidth
				implicitWidth: row.visible ? row.implicitWidth : 0
				height: rowItem.separator ? root.separatorHeight : row.height

				Separator {
					visible: rowItem.separator
					anchors.verticalCenter: parent.verticalCenter
					width: rowItem.width
					height: Config.trayMenuSeparator
					color: Config.rule
				}

				MenuRow {
					id: row

					visible: !rowItem.separator
					width: rowItem.width
					text: root.armed === rowItem.index && modelData.confirmLabel ? modelData.confirmLabel : modelData.label !== undefined ? modelData.label : modelData.text !== undefined ? modelData.text : String(modelData)
					icon: modelData.icon || ""
					danger: modelData.danger === true
					enabled: modelData.enabled !== false
					current: modelData.checkState === 2 || (root.current !== undefined && (modelData.value !== undefined ? modelData.value : modelData) === root.current)
					armed: root.armed === rowItem.index
					submenu: rowItem.submenu
					selected: rowItem.submenu && root.openIndex === rowItem.index
					flush: !root.framed

					onHoveredChanged: {
						if (hovered && enabled)
							root.openIndex = rowItem.submenu ? rowItem.index : -1;
					}

					onClicked: root.activate(rowItem.index, rowItem.modelData)
				}
			}
		}

		Hint {
			x: Config.appControlRadius
			shown: root.armed >= 0 && root.armed < root.entries.length && (root.entries[root.armed].hint || "") !== ""
			inkMuted: Config.red
			text: root.armed >= 0 && root.armed < root.entries.length ? root.entries[root.armed].hint || "" : ""
		}
	}

	QQC.Popup {
		parent: root.openIndex >= 0 ? root.rowAt(root.openIndex) : null
		x: parent ? parent.width + Config.gapsIn : 0
		y: 0
		padding: 0
		background: null
		focus: false
		closePolicy: QQC.Popup.NoAutoClose
		visible: root.submenuOpen && !root.overlay

		contentItem: Loader {
			width: implicitWidth
			height: implicitHeight
			active: root.submenuOpen && !root.overlay
			sourceComponent: root.panelComponent
			onLoaded: root.attach(item)
		}
	}

	Loader {
		active: root.overlay
		sourceComponent: layerComponent
	}

	Component {
		id: layerComponent

		Tooltip {
			beside: true
			shown: root.submenuOpen && root.overlay
			anchorWindow: root.anchorWindow
			anchorItem: root.openIndex >= 0 ? root.rowAt(root.openIndex) : null
			contentPadding: 0

			Loader {
				active: root.submenuOpen && root.overlay
				sourceComponent: root.panelComponent
				onLoaded: root.attach(item)
			}
		}
	}
}
