import QtQuick
import qs
import qs.ui

Item {
	id: root

	property bool searchable: false
	property string query: ""
	property string title: ""

	default property alias content: body.data
	property alias tools: topSlot.data

	signal searchDown()

	anchors.fill: parent

	function clearSearch() {
		search.clear();
	}

	Column {
		id: head

		x: Metrics.gapSmall * 3
		y: Metrics.gap
		width: root.width - x * 2
		spacing: Metrics.gapSmall * 3

		Item {
			width: parent.width
			height: Metrics.chipHeight
			visible: root.title !== "" || topSlot.children.length > 0

			Label {
				id: titleLabel

				anchors.left: parent.left
				anchors.leftMargin: Metrics.gapSmall
				anchors.right: topSlot.left
				anchors.rightMargin: Metrics.gapSmall
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: titleLabel.capOffset
				role: "heading"
				text: root.title
			}

			Row {
				id: topSlot

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				spacing: Metrics.gapSmall
			}
		}

		SearchField {
			id: search

			visible: root.searchable
			width: parent.width
			boxHeight: Metrics.chipHeight + Metrics.gapSmall
			boxColor: AppPalette.raised
			corner: Metrics.controlRadius
			padding: Metrics.gapSmall * 2
			glyph: Config.glyph("search")
			size: Metrics.bodySize
			glyphSize: Metrics.bodySize
			placeholder: "Search"
			typing: root.searchable
			onEdited: root.query = search.text
			onKeyPressed: function (event) {
				if (event.key === Qt.Key_Down) {
					root.searchDown();
					event.accepted = true;
				}
			}
		}
	}

	Item {
		id: body

		anchors.top: head.bottom
		anchors.topMargin: Metrics.gapSmall * 3
		anchors.bottom: parent.bottom
		width: parent.width
	}

	onQueryChanged: if (search.text !== root.query) search.text = root.query
}
