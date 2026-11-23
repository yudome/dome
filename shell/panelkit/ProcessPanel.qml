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
	property color listInk: Config.foreground
	property color totalInk: Config.foreground
	property bool showTotal: true
	property string totalOverride: ""
	property int topCount: Config.cpuTopCount
	property string psField: "pcpu"
	property var rowColor: (row) => row.color || Config.foreground
	property bool showProcessList: true
	property alias viz: vizColumn.data

	property string filter: ""

	readonly property bool searching: searchField.typing
	readonly property bool filtering: panel.searching || panel.filter !== ""
	property var procs: []
	readonly property bool showList: panel.showProcessList && (panel.procs.length > 0 || panel.filtering)
	readonly property real pct: panel.source ? panel.source.pct : 0
	readonly property bool onScreen: panel.Window.window ? panel.Window.window.visible : false
	property var keyAction: null

	signal query(string field, string filter)
	signal kill(var proc)

	onOnScreenChanged: {
		panel.query(panel.psField, panel.filter);

		if (!panel.onScreen) {
			searchField.clear();
			searchField.typing = false;
			panel.filter = "";
			return;
		}

		procList.currentIndex = -1;
		procList.reset();

		if (panel.source && panel.source.refresh)
			panel.source.refresh();
	}

	onFilterChanged: panel.query(panel.psField, panel.filter)

	onSearchingChanged: {
		if (!panel.searching)
			panel.forceActiveFocus();
	}

	Keys.onPressed: function (event) {
		if (panel.searching)
			return;

		if (Input.hint(event)) {
			searchField.startTyping();
			event.accepted = true;
		} else if (Input.cancel(event)) {
			panel.closeRequested();
			event.accepted = true;
		} else if (panel.keyAction !== null && panel.keyAction(event)) {
			return;
		} else {
			procList.handleKey(event);
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

		Rectangle {
			id: headerBox

			width: column.width
			height: searchField.implicitHeight
			visible: panel.showList
			color: Config.surfaceRaised
			radius: 0

			Label {
				id: listTitle

				anchors.left: parent.left
				anchors.leftMargin: Config.procSearchPadding
				anchors.verticalCenter: parent.verticalCenter
				ink: panel.listInk
				text: Config.topProcessTitle
			}

			SearchField {
				id: searchField

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				boxColor: "transparent"
				size: Config.fontSize
				width: searchField.implicitWidth
				candidate: panel.filter !== "" && panel.procs.length > 0 ? String(panel.procs[0].name) : ""

				onEdited: panel.filter = searchField.text
			}
		}

		ProcessList {
			id: procList

			width: column.width
			visibleRows: panel.topCount
			visible: panel.showList
			model: panel.procs

			onKillRequested: function (proc) {
				panel.kill(proc);
			}

			delegate: Item {
				id: row

				required property var modelData
				required property int index

				readonly property bool active: procList.currentIndex === row.index

				width: ListView.view.rowWidth
				height: ListView.view.rowHeight

				Highlight {
					id: hl

					active: row.active
					radius: 0
				}

				Label {
					id: process

					anchors.left: parent.left
					anchors.leftMargin: Config.rowInset
					anchors.right: amount.left
					anchors.rightMargin: Config.gapsIn * 2
					anchors.verticalCenter: parent.verticalCenter
					ink: hl.ink
					text: row.modelData.name
				}

				Label {
					id: amount

					anchors.right: parent.right
					anchors.rightMargin: Config.rowInset
					anchors.verticalCenter: parent.verticalCenter
					role: "value"
					ink: panel.rowColor(row.modelData)
					text: row.modelData.valueText
				}

				MouseArea {
					anchors.fill: parent

					onClicked: {
						if (row.active)
							procList.killRequested(row.modelData);
						else
							procList.currentIndex = row.index;
					}
				}
			}
		}
	}
}
