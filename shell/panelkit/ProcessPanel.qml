pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs
import qs.ui

PanelPage {
	id: panel

	property var source: null
	property string title: ""
	property string detail: ""
	property color detailColor: Config.foreground
	property color totalInk: Config.foreground
	property bool showTotal: true
	property string totalOverride: ""
	property alias viz: vizColumn.data
	property var keyAction: null

	readonly property real pct: panel.source ? panel.source.pct : 0
	readonly property bool onScreen: panel.Window.window ? panel.Window.window.visible : false

	onOnScreenChanged: {
		if (panel.onScreen && panel.source && panel.source.refresh)
			panel.source.refresh();
	}

	Keys.onPressed: function (event) {
		if (Input.cancel(event)) {
			panel.closeRequested();
			event.accepted = true;
		} else if (panel.keyAction !== null) {
			panel.keyAction(event);
		}
	}

	Column {
		id: column

		width: panel.contentWidth
		spacing: Config.gapsIn * 1.5

		PanelHeader {
			width: column.width
			title: panel.title
			value: panel.showTotal ? (panel.totalOverride !== "" ? panel.totalOverride : Math.round(panel.pct) + "%") : ""
			valueInk: panel.totalInk
		}

		Label {
			width: column.width
			visible: text !== ""
			ink: panel.detailColor
			text: panel.detail
		}

		Item {
			id: vizSlot

			width: column.width
			height: vizColumn.implicitHeight

			Column {
				id: vizColumn

				width: parent.width
				spacing: 6
			}
		}
	}
}
