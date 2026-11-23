pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit
import qs.services

AppSection {
	id: root

	required property var store

	readonly property var list: root.store.wallpapers
	readonly property real tileMin: Metrics.controlWidth * 0.8
	readonly property int columns: Math.max(2, Math.floor((root.width + Metrics.gap) / root.tileMin))
	readonly property real tile: (root.width - (root.columns - 1) * Metrics.gap) / root.columns

	title: "Wallpapers"
	carded: false

	EmptyState {
		anchors.horizontalCenter: parent.horizontalCenter
		visible: root.list.length === 0
		icon: "wallpaper"
		text: "No wallpapers"
	}

	Flow {
		width: root.width
		spacing: Metrics.gap

		Repeater {
			model: root.list

			delegate: Column {
				id: entry

				required property var modelData

				readonly property bool active: root.store.wallpaper === entry.modelData.path

				width: root.tile
				spacing: Metrics.gapSmall * 2

				Card {
					id: picture

					width: parent.width
					height: Math.round(width / 1.6)
					inset: 0
					hoverable: true
					selected: entry.active
					clip: true
					onClicked: root.store.pickWallpaper(entry.modelData.path)

					Image {
						width: picture.width
						height: picture.height
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						sourceSize.width: Metrics.controlWidth
						source: "file://" + (entry.modelData.thumb || entry.modelData.path)
						opacity: entry.active || picture.hovered ? 1 : 0.8
					}
				}

				Label {
					width: parent.width
					role: "caption"
					ink: entry.active ? AppPalette.ink : AppPalette.inkMuted
					text: entry.modelData.name || ""
				}
			}
		}
	}
}
