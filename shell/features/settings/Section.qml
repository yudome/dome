pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui

Column {
	id: root

	required property var section
	required property var store
	property bool open: false

	readonly property var main: root.section.keys.filter(function (k) { return !k.advanced; })
	readonly property var fine: root.section.keys.filter(function (k) { return k.advanced; })

	spacing: Config.settingsGap / 2

	Component {
		id: fieldRow

		Field {
			required property var modelData

			entry: modelData
			value: root.store.value(modelData.key)
			changed: root.store.pending[modelData.key] !== undefined
			onSet: function (next) { root.store.setValue(modelData.key, next); }
		}
	}

	Text {
		width: parent.width
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsSmallSize
		font.letterSpacing: 1
		color: Config.settingsLabel
		text: (root.section.comment || root.section.name).toUpperCase()
	}

	Rectangle {
		width: parent.width
		height: card.height + Config.settingsGap
		radius: Config.settingsRadius
		color: Config.settingsCard

		Column {
			id: card

			x: Config.settingsGap
			y: Config.settingsGap / 2
			width: parent.width - Config.settingsGap * 2

			Repeater {
				model: root.main
				delegate: fieldRow
			}

			Item {
				width: parent.width
				height: Config.settingsRowHeight
				visible: root.fine.length > 0

				Glyph {
					id: chevron

					anchors.verticalCenter: parent.verticalCenter
					width: 14
					height: 14
					size: Config.settingsSmallSize
					color: Config.settingsLabel
					glyph: root.open ? Config.iconDown : Config.iconRight
				}

				Text {
					anchors.left: chevron.right
					anchors.leftMargin: 8
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					elide: Text.ElideRight
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsFontSize
					color: Config.settingsLabel
					text: "Advanced"
				}

				MouseArea {
					anchors.fill: parent
					onClicked: root.open = !root.open
				}
			}

			Repeater {
				model: root.open ? root.fine : []
				delegate: fieldRow
			}
		}
	}
}
