pragma ComponentBehavior: Bound

import QtQuick
import qs.ui
import qs.appkit

Item {
	id: root

	required property var store

	anchors.fill: parent

	ListView {
		id: list

		x: Metrics.gapSmall * 3
		width: parent.width - x * 2
		anchors.top: parent.top
		anchors.bottom: totals.top
		clip: true
		model: root.store.selectedRows
		spacing: Metrics.border
		boundsBehavior: Flickable.StopAtBounds
		acceptedButtons: Qt.NoButton

		delegate: ListRow {
			id: row

			required property var modelData

			width: list.width
			icon: root.store.glyphOf(row.modelData)
			title: row.modelData.name || row.modelData.label || ""

			leading: Component {
				Check {
					checked: true
					onToggled: root.store.unselect(row.modelData)
				}
			}

			Label {
				anchors.verticalCenter: parent.verticalCenter
				role: "caption"
				text: row.modelData.sizeText || ""
			}
		}
	}

	AppScroll {
		anchors.fill: list
		view: list
	}

	EmptyState {
		anchors.centerIn: list
		visible: list.count === 0
		icon: "check"
		text: "Nothing selected"
	}

	Column {
		id: totals

		anchors.bottom: parent.bottom
		anchors.bottomMargin: Metrics.gapSmall * 3
		x: Metrics.gapSmall * 3
		width: parent.width - x * 2
		spacing: Metrics.gapSmall * 2

		Item {
			width: parent.width
			height: Metrics.chipHeight

			Label {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				role: "caption"
				text: "Total"
			}

			Label {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				role: "value"
				text: root.store.selectedTotal > 0 ? root.store.formatSize(root.store.selectedTotal) : ""
			}
		}

		Button {
			width: parent.width
			action: root.store.cleanAction
		}
	}
}
