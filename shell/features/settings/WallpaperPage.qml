pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.services

Column {
	id: root

	readonly property var list: Yudae.wallpaper.list || []
	readonly property int columns: Math.max(2, Math.floor((root.width + Config.settingsGap) / 220))
	readonly property real tile: (root.width - (root.columns - 1) * Config.settingsGap) / root.columns

	spacing: 12

	Text {
		width: root.width
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsFontSize + 3
		color: Config.foreground
		text: "Wallpapers"
	}

	Text {
		width: root.width
		visible: root.list.length === 0
		wrapMode: Text.WordWrap
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsFontSize + 1
		color: Config.settingsLabel
		text: "No wallpapers in the wallpaper folder yet"
	}

	Flow {
		width: root.width
		spacing: Config.settingsGap

		Repeater {
			model: root.list

			delegate: Item {
				id: card

				required property var modelData

				readonly property bool active: Yudae.wallpaper.active === card.modelData.path

				width: root.tile
				height: picture.height + 28

				Rectangle {
					anchors.fill: picture
					anchors.margins: -3
					radius: Config.settingsRadius - 2
					color: "transparent"
					border.width: 2
					border.color: Config.foreground
					visible: card.active
				}

				Rectangle {
					id: picture

					width: parent.width
					height: Math.round(width / 1.6)
					radius: Config.settingsRadius - 4
					color: Config.settingsCard
					clip: true

					Image {
						anchors.fill: parent
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						sourceSize.width: 320
						source: "file://" + (card.modelData.thumb || card.modelData.path)
						opacity: card.active || hover.containsMouse ? 1 : 0.8
					}
				}

				Text {
					anchors.top: picture.bottom
					anchors.topMargin: 8
					width: parent.width
					elide: Text.ElideRight
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsSmallSize
					color: card.active ? Config.foreground : Config.settingsLabel
					text: card.modelData.name || ""
				}

				MouseArea {
					id: hover

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: Yudae.cmd("wallpaper", { apply: { path: card.modelData.path } })
				}
			}
		}
	}
}
