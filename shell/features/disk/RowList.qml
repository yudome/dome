pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit

Item {
	id: root

	property var rows: []
	property var selected: ({})
	property string sortKey: "size"
	property bool sortDesc: true

	readonly property string sizeClass: Metrics.sizeClass(Window.width)
	readonly property bool compact: root.sizeClass === "compact"
	readonly property real padding: Metrics.paddingFor(root.sizeClass)
	readonly property var ordered: {
		const needle = search.text.trim().toLowerCase();
		const list = root.rows.filter(function (r) {
			return needle === "" || (String(r.name) + " " + String(r.detail)).toLowerCase().indexOf(needle) >= 0;
		});
		const key = root.sortKey;
		const dir = root.sortDesc ? -1 : 1;
		list.sort(function (a, b) {
			if (key === "name")
				return dir * String(a.name).localeCompare(String(b.name));
			return dir * ((Number(a.size) || 0) - (Number(b.size) || 0));
		});
		return list;
	}

	signal toggled(var row)

	onOrderedChanged: list.contentY = 0

	function sortBy(key) {
		if (root.sortKey === key)
			root.sortDesc = !root.sortDesc;
		else {
			root.sortKey = key;
			root.sortDesc = key === "size";
		}
	}

	SearchField {
		id: search

		anchors.left: parent.left
		anchors.leftMargin: root.padding
		anchors.right: sorts.left
		anchors.rightMargin: Metrics.gap
		anchors.top: parent.top
		anchors.topMargin: Metrics.gapSmall * 2
		boxHeight: Metrics.chipHeight + Metrics.gapSmall
		boxColor: AppPalette.raised
		corner: Metrics.controlRadius
		padding: Metrics.gapSmall * 2
		glyph: Config.glyph("search")
		size: Metrics.bodySize
		glyphSize: Metrics.bodySize
		placeholder: "Search"
		typing: true
		candidate: root.ordered.length > 0 ? String(root.ordered[0].name) : ""
	}

	Row {
		id: sorts

		anchors.right: parent.right
		anchors.rightMargin: root.padding
		anchors.verticalCenter: search.verticalCenter
		spacing: Metrics.gapSmall * 2

		Repeater {
			model: [{ label: "Name", value: "name" }, { label: "Size", value: "size" }]

			delegate: Chip {
				required property var modelData

				selected: root.sortKey === modelData.value
				text: modelData.label
				glyph: selected ? (root.sortDesc ? Config.diskIconSortDesc : Config.diskIconSortAsc) : ""
				onClicked: root.sortBy(modelData.value)
			}
		}
	}

	ListView {
		id: list

		anchors.left: parent.left
		anchors.leftMargin: root.padding
		anchors.right: parent.right
		anchors.rightMargin: root.padding
		anchors.top: search.bottom
		anchors.topMargin: Metrics.gap
		anchors.bottom: parent.bottom
		clip: true
		model: root.ordered
		boundsBehavior: Flickable.StopAtBounds
		acceptedButtons: Qt.NoButton

		delegate: ListRow {
			id: row

			required property var modelData

			width: list.width
			height: Metrics.chipHeight + Metrics.gapSmall
			hoverable: true
			selected: root.selected[row.modelData.key] !== undefined
			title: row.modelData.name
			onActivated: root.toggled(row.modelData)

			leading: Component {
				Check {
					checked: row.selected
					onToggled: root.toggled(row.modelData)
				}
			}

			Label {
				anchors.verticalCenter: parent.verticalCenter
				visible: !root.compact
				width: row.width * 0.34
				role: "caption"
				elide: Text.ElideMiddle
				text: row.modelData.detail
			}

			Label {
				anchors.verticalCenter: parent.verticalCenter
				visible: !root.compact
				width: Metrics.chipHeight * 2.6
				role: "value"
				text: row.modelData.sizeText
			}
		}
	}

	AppScroll {
		anchors.fill: list
		view: list
	}

	EmptyState {
		anchors.centerIn: list
		visible: list.count === 0 && search.text !== ""
		icon: "search"
		text: "No matches"
	}
}
