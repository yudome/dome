import QtQuick
import qs.ui
import qs.panelkit
import qs.services
import qs

PanelPage {
	id: root

	signal refreshRequested()

	readonly property var cells: Github.grid
	readonly property int weeks: Config.contribWeeks
	readonly property color accentInk: Config.foreground

	contentWidth: Config.contribTooltipWidth

	onVisibleChanged: {
		if (root.visible)
			Github.refresh(false);
	}

	function statusLine() {
		if (Github.login === "")
			return Github.status !== "" ? Github.status : "looking for your GitHub user";

		return "@" + Github.login;
	}

	Keys.onPressed: function (event) {
		Input.github(event, root);
	}

	Column {
		id: column

		width: Config.contribTooltipWidth
		spacing: 6

		Item {
			id: person

			width: column.width
			height: Math.max(slot.height, who.implicitHeight, year.implicitHeight)

			Rectangle {
				id: slot

				width: Config.contribAvatar
				height: Config.contribAvatar
				color: Config.surfaceRaised
				clip: true

				Icon {
					anchors.centerIn: parent
					visible: avatar.status !== Image.Ready
					size: Math.round(slot.height * 0.6)
					ink: root.accentInk
					glyph: Config.iconGithub
				}

				Image {
					id: avatar

					anchors.fill: parent
					source: Github.login !== "" ? "https://github.com/" + Github.login + ".png" : ""
					sourceSize.width: Config.contribAvatar * 2
					fillMode: Image.PreserveAspectCrop
					visible: status === Image.Ready
				}
			}

			Label {
				id: who

				anchors.left: slot.right
				anchors.leftMargin: Config.notifySlotGap
				anchors.verticalCenter: parent.verticalCenter
				width: Math.max(0, person.width - slot.width - year.width - Config.notifySlotGap * 2)
				elide: Text.ElideRight
				ink: root.accentInk
				text: root.statusLine()
			}

			Label {
				id: year

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				ink: root.accentInk
				text: Github.total > 0 ? Github.total + " this year" : ""
			}

		}

		Item {
			id: legend

			readonly property int step: Config.contribCell + Config.contribGap
			readonly property int base: Math.ceil((less.implicitWidth + Config.contribGap) / legend.step)

			width: column.width
			height: Config.contribCell

			Label {
				id: less

				x: 0
				anchors.verticalCenter: parent.verticalCenter
				font.pixelSize: Config.notifyAppFontSize
				ink: Config.muted
				text: "less"
			}

			Repeater {
				model: 5

				delegate: Rectangle {
					required property int index

					x: (legend.base + index) * legend.step
					anchors.verticalCenter: parent.verticalCenter
					width: Config.contribCell
					height: Config.contribCell
					color: Github.levelInk[index] || Config.contribEmpty
				}
			}

			Label {
				id: more

				x: (legend.base + 5) * legend.step
				anchors.verticalCenter: parent.verticalCenter
				font.pixelSize: Config.notifyAppFontSize
				ink: Config.muted
				text: "more"
			}
		}

		CellGrid {
			id: grid

			values: root.cells
			columns: root.weeks
			cellSize: Config.contribCell
			gap: Config.contribGap
			colorFor: (value) => Github.levelInk[value ? value.level : 0] || Config.contribEmpty
		}

		Row {
			width: column.width
			spacing: Config.spacing

			Label {
				visible: text !== ""
				role: "caption"
				text: Github.loading ? "Refreshing" : (Github.fetched > 0 ? "Updated " + Qt.formatDateTime(new Date(Github.fetched), "MMM d h:mm AP") : "")
			}

			Hint {
				shown: !Github.loading
				line: Github.fetched > 0 ? Config.contribRefreshHint : Config.contribFetchHint
			}
		}
	}
}
