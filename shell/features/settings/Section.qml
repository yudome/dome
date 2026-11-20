pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import "Toml.js" as Toml

Item {
	id: root

	required property var section
	required property var store
	property bool open: false

	readonly property var main: root.section.keys.filter(function (k) { return !k.advanced; })
	readonly property var fine: root.section.keys.filter(function (k) { return k.advanced; })
	readonly property var shown: root.main.length === 0 ? root.fine : root.main
	readonly property bool folds: root.main.length > 0 && root.fine.length > 0
	readonly property var rows: root.shown.concat(root.folds && root.open ? root.fine : [])

	height: heading.height + 12 + panel.height

	Text {
		id: heading

		width: root.width
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsFontSize + 3
		color: Config.foreground
		text: Toml.titles[root.section.name] || Toml.label(root.section.name, "")
	}

	Rectangle {
		id: panel

		y: heading.height + 12
		width: root.width
		height: list.height
		radius: Config.settingsRadius
		color: Config.settingsCard

		Column {
			id: list

			x: Config.settingsGap + 4
			width: parent.width - x * 2

			Component {
				id: fieldRow

				Field {
					required property var modelData
					required property int index

					entry: modelData
					value: root.store.value(modelData.key)
					changed: root.store.pending[modelData.key] !== undefined
					last: index === root.rows.length - 1 && !root.folds
					onSet: function (next) { root.store.setValue(modelData.key, next); }
				}
			}

			Repeater {
				model: root.rows
				delegate: fieldRow
			}

			Item {
				width: parent.width
				height: Config.settingsRowHeight - 4
				visible: root.folds

				Text {
					id: moreText

					anchors.verticalCenter: parent.verticalCenter
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsFontSize
					color: moreHover.containsMouse ? Config.foreground : Config.settingsLabel
					text: root.open ? "Fewer options" : "More options"
				}

				Glyph {
					anchors.left: moreText.right
					anchors.leftMargin: 8
					anchors.verticalCenter: parent.verticalCenter
					width: 12
					height: 12
					size: Config.settingsSmallSize - 2
					color: moreText.color
					glyph: root.open ? Config.iconUp : Config.iconDown
				}

				MouseArea {
					id: moreHover

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.open = !root.open
				}
			}
		}
	}
}
