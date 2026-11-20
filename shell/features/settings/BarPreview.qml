pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.services

Rectangle {
	id: root

	required property var store
	required property var layout
	required property var glyphs
	property string part: "left"

	readonly property var monitor: Yudae.screenActive || ({ width: 1920, height: 1080, scale: 1 })
	readonly property real screenWidth: Math.round(root.monitor.width / (root.monitor.scale || 1))
	readonly property real screenHeight: Math.round(root.monitor.height / (root.monitor.scale || 1))
	readonly property var bar: root.layout && root.layout.bar ? root.layout.bar : ({})
	readonly property var slots: root.bar.layout || ({})
	readonly property bool atBottom: root.bar.position === "bottom"
	readonly property real span: Math.min(root.width - 12, root.screenWidth)
	readonly property real offset: root.part === "left" ? 0 : root.part === "right" ? root.screenWidth - root.span : Math.round((root.screenWidth - root.span) / 2)
	readonly property real outer: root.v("barFloating") === true ? root.v("gapsOut") : 0
	readonly property real borderWidth: root.v("barBorderWidth") < 0 ? root.v("borderFallbackWidth") : root.v("barBorderWidth")
	readonly property real inset: root.v("barInset") + Math.max(0, root.borderWidth)
	readonly property real contentHeight: Math.max(root.v("fontSize"), root.v("iconSize")) + Math.ceil(root.v("barThickness")) + 4
	readonly property real barHeight: Math.ceil(root.contentHeight) + root.inset * 2
	readonly property real stripHeight: root.barHeight + root.outer + Config.settingsPreviewBelow

	height: header.height + strip.height + Config.settingsGap * 2 + 12
	radius: Config.settingsRadius
	color: Config.settingsCard

	function v(key) {
		const value = root.store.value(key);
		return value !== undefined ? value : Config[key];
	}

	function ink(base) {
		return root.v("mono") === true || root.v("barStatMono") === true ? root.v("foreground") : v(base);
	}

	readonly property var stats: ({
		cpu: { base: "cpuBase", sample: "12%", fill: 0.3 },
		memory: { base: "memoryBase", sample: "41%", fill: 0.4 },
		volume: { base: "volumeBase", sample: "70%", fill: 0.7 },
		power: { base: "powerBase", sample: "88%", fill: 0.88 },
		network: { base: "networkBase", sample: "4G", fill: 0.6 }
	})

	Item {
		id: header

		x: Config.settingsGap + 4
		y: Config.settingsGap
		width: root.width - x * 2
		height: partSwitch.height

		Text {
			anchors.left: parent.left
			anchors.right: partSwitch.left
			anchors.rightMargin: Config.settingsGap
			anchors.verticalCenter: parent.verticalCenter
			elide: Text.ElideRight
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsFontSize + 1
			color: Config.foreground
			text: "Preview"
		}

		PillSwitch {
			id: partSwitch

			anchors.right: parent.right
			model: [{ label: "Left", value: "left" }, { label: "Center", value: "center" }, { label: "Right", value: "right" }]
			selected: ["left", "center", "right"].indexOf(root.part)
			onPick: function (next) { root.part = next; }
		}
	}

	Rectangle {
		id: strip

		x: 6
		y: header.y + header.height + 12
		width: root.width - 12
		height: root.stripHeight
		radius: Config.settingsRadius - 4
		color: Config.surface
		clip: true

		Image {
			x: -root.offset
			y: root.atBottom ? -(root.screenHeight - root.stripHeight) : 0
			width: root.screenWidth
			height: root.screenHeight
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			sourceSize.width: root.screenWidth
			source: Yudae.wallpaper.active ? "file://" + Yudae.wallpaper.active : ""
		}

		Item {
			x: -root.offset
			y: root.atBottom ? root.stripHeight - root.barHeight - root.outer : root.outer
			width: root.screenWidth
			height: root.barHeight

			Rectangle {
				x: root.outer
				width: parent.width - root.outer * 2
				height: parent.height
				color: root.bar.transparent === true ? "transparent" : root.v("surfaceTranslucent")
				border.width: Math.max(0, root.borderWidth)
				border.color: root.v("borderFallbackColor")
			}

			Row {
				id: leftRow

				x: root.outer + root.inset + root.v("barPadding")
				anchors.bottom: parent.bottom
				anchors.bottomMargin: root.inset
				spacing: root.v("spacing")

				Repeater {
					model: root.slots.left || []
					delegate: chip
				}
			}

			Row {
				id: centerRow

				readonly property var anchorItem: {
					const ids = (root.slots.center || []).map(function (e) { return e.id; });
					const at = ids.indexOf(root.bar.centerAnchor);
					return at >= 0 ? centerRepeater.itemAt(at) : null;
				}

				x: Math.round(parent.width / 2 - (centerRow.anchorItem ? centerRow.anchorItem.x + centerRow.anchorItem.width / 2 : centerRow.width / 2))
				anchors.bottom: parent.bottom
				anchors.bottomMargin: root.inset
				spacing: root.v("spacing")

				Repeater {
					id: centerRepeater

					model: root.slots.center || []
					delegate: chip
				}
			}

			Row {
				anchors.right: parent.right
				anchors.rightMargin: root.outer + root.inset + root.v("barPadding")
				anchors.bottom: parent.bottom
				anchors.bottomMargin: root.inset
				spacing: root.v("barStatSpacing")

				Repeater {
					model: root.slots.right || []
					delegate: chip
				}
			}
		}
	}

	Component {
		id: chip

		Item {
			id: cell

			required property var modelData

			readonly property string name: modelData.id
			readonly property var stat: root.stats[cell.name] || null
			readonly property bool textMode: cell.stat !== null && root.v("barStatMode") === "text"
			readonly property string sample: cell.name === "clock" ? Qt.formatDateTime(new Date(2026, 10, 19, 9, 41), root.v("clockFormat")) : cell.name === "weather" ? "18°" : cell.textMode ? cell.stat.sample : ""
			readonly property color tone: cell.stat ? root.ink(cell.stat.base) : root.v("foreground")

			width: cell.name === "spacer" ? root.v("spacing") : row.width
			height: row.height + (cell.stat ? Math.ceil(root.v("barThickness")) + 2 : 0)

			Row {
				id: row

				spacing: 4
				visible: cell.name !== "spacer"

				Glyph {
					visible: !cell.textMode && cell.name !== "clock"
					width: root.v("iconSize") + 4
					height: Math.max(root.v("iconSize"), root.v("fontSize")) + 4
					size: root.v("iconSize")
					color: cell.tone
					glyph: Config.glyph(root.glyphs[cell.name] || "")
				}

				Text {
					visible: cell.sample !== ""
					height: Math.max(root.v("iconSize"), root.v("fontSize")) + 4
					verticalAlignment: Text.AlignVCenter
					font.family: root.v("fontFamily")
					font.pixelSize: root.v("fontSize")
					color: cell.tone
					text: cell.sample
				}
			}

			Rectangle {
				visible: cell.stat !== null
				anchors.bottom: parent.bottom
				width: row.width
				height: root.v("barThickness")
				color: root.v("dim")

				Rectangle {
					width: parent.width * (cell.stat ? cell.stat.fill : 0)
					height: parent.height
					color: cell.tone
				}
			}
		}
	}
}
