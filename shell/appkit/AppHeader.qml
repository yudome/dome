pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
import qs
import qs.ui

Item {
	id: root

	property string title: ""
	property bool back: false
	property string backIcon: "chevron"
	property bool ruled: false
	property var actions: []
	property real column: 0
	property string sizeClass: Metrics.sizeClass(Window.width)

	default property alias trailing: extra.data

	readonly property bool compact: root.sizeClass === "compact"
	readonly property real inset: Metrics.paddingFor(root.sizeClass)
	readonly property real lane: root.column > 0 ? Math.min(root.column, root.width - root.inset * 2) : root.width - root.inset * 2

	signal backClicked()

	width: parent ? parent.width : 0
	height: Metrics.headerHeight

	Rectangle {
		anchors.fill: parent
		color: AppPalette.surface
	}

	Rectangle {
		anchors.bottom: parent.bottom
		width: parent.width
		height: Metrics.border
		color: AppPalette.rule
		opacity: root.ruled ? 1 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: Motion.toggleMs
			}
		}
	}

	Item {
		x: Math.round((root.width - root.lane) / 2)
		width: root.lane
		height: parent.height

		IconButton {
			id: backButton

			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			visible: root.back
			name: root.backIcon
			label: "Back"
			onClicked: root.backClicked()
		}

		Label {
			id: titleLabel

			anchors.left: backButton.visible ? backButton.right : parent.left
			anchors.leftMargin: backButton.visible ? Metrics.gapSmall * 2 : 0
			anchors.right: tail.left
			anchors.rightMargin: Metrics.gap
			anchors.verticalCenter: parent.verticalCenter
			anchors.verticalCenterOffset: titleLabel.capOffset
			role: "title"
			text: root.title
		}

		Row {
			id: tail

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: Metrics.gapSmall * 2

			Row {
				id: extra

				anchors.verticalCenter: parent.verticalCenter
				spacing: Metrics.gapSmall * 2
			}

			Repeater {
				model: root.compact ? [] : root.actions

				delegate: Button {
					required property var modelData

					anchors.verticalCenter: parent ? parent.verticalCenter : undefined
					action: modelData
				}
			}

			IconButton {
				id: more

				anchors.verticalCenter: parent.verticalCenter
				visible: root.compact && root.actions.length > 0
				name: "more"
				label: "Actions"
				selected: menu.opened
				onClicked: menu.opened ? menu.close() : menu.open()

				QQC.Popup {
					id: menu

					x: more.width - width
					y: more.height + Metrics.gapSmall
					padding: 0
					background: null

					contentItem: MenuList {
						entries: root.actions.map(function (a) {
							return { label: a.text, icon: a.icon, danger: a.kind === "danger", enabled: a.enabled && !a.busy, action: a };
						})
						onPicked: function (entry) {
							menu.close();
							entry.action.run();
						}
					}
				}
			}
		}
	}
}
