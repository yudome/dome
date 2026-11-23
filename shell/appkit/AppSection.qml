import QtQuick
import qs
import qs.ui

Column {
	id: root

	property string title: ""
	property bool carded: true

	default property alias rows: card.content
	property alias tools: topSlot.data

	width: parent ? parent.width : 0
	spacing: Metrics.gapSmall * 3

	Item {
		width: root.width
		height: Math.max(heading.implicitHeight, topSlot.height)
		visible: root.title !== "" || topSlot.children.length > 0

		Label {
			id: heading

			anchors.left: parent.left
			anchors.right: topSlot.left
			anchors.rightMargin: Metrics.gap
			anchors.verticalCenter: parent.verticalCenter
			role: "heading"
			text: root.title
		}

		Row {
			id: topSlot

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: Metrics.gapSmall * 2
		}
	}

	Card {
		id: card

		width: root.width
		color: root.carded ? AppPalette.raised : "transparent"
		inset: root.carded ? Metrics.gap + Metrics.gapSmall : 0
	}
}
