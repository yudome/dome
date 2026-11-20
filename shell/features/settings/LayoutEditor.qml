pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import "Toml.js" as Toml

Item {
	id: root

	required property var store
	required property var library

	readonly property var layout: root.store.layout ? root.store.layout.bar.layout : ({ left: [], center: [], right: [] })
	readonly property var slotNames: ["left", "center", "right"]
	property var drag: null
	property var targets: []

	width: parent ? parent.width : 0
	height: column.height

	function title(id) {
		return id.charAt(0).toUpperCase() + id.slice(1);
	}

	function glyphOf(id) {
		const found = root.library.find(function (f) { return f.id === id; });
		return found ? Config.glyph(found.glyph) : "";
	}

	function begin(from, index, id, item, mouse) {
		const at = item.mapToItem(root, mouse.x, mouse.y);
		root.drag = { from: from, index: index, id: id, x: at.x, y: at.y, dx: mouse.x, dy: mouse.y };
	}

	function follow(item, mouse) {
		if (!root.drag)
			return;
		const at = item.mapToItem(root, mouse.x, mouse.y);
		root.drag = Object.assign({}, root.drag, { x: at.x, y: at.y });
	}

	function inside(target) {
		const at = target.mapFromItem(root, root.drag.x, root.drag.y);
		return at.x >= 0 && at.y >= 0 && at.x <= target.width && at.y <= target.height;
	}

	function finish() {
		const d = root.drag;
		root.drag = null;
		if (!d)
			return;

		for (let s = 0; s < root.targets.length; s++) {
			const slot = root.targets[s];
			if (!root.inside(slot.area))
				continue;
			const p = slot.flow.mapFromItem(root, d.x, d.y);
			let index = 0;
			for (let i = 0; i < slot.list.count; i++) {
				const c = slot.list.itemAt(i);
				if (c && (c.y + c.height <= p.y || (c.y <= p.y && c.x + c.width / 2 < p.x)))
					index = i + 1;
			}
			root.store.setLayout(Toml.move(root.store.layout, d.from, d.from ? d.index : d.id, slot.name, index));
			return;
		}

		if (d.from && root.inside(libraryBox))
			root.store.setLayout(Toml.move(root.store.layout, d.from, d.index, null, 0));
	}

	Column {
		id: column

		width: parent.width
		spacing: Config.settingsGap

		Text {
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			font.letterSpacing: 1
			color: Config.settingsLabel
			text: "LAYOUT"
		}

		Repeater {
			id: slotRepeater

			model: root.slotNames

			delegate: Item {
				id: slot

				required property string modelData

				required property int index

				readonly property string name: modelData

				Component.onCompleted: root.targets[slot.index] = { name: slot.name, area: box, flow: chips, list: chipRepeater }

				width: column.width
				height: box.height

				Rectangle {
					id: box

					width: parent.width
					height: Math.max(Config.settingsChipHeight, chips.height) + Config.settingsGap
					radius: Config.settingsRadius
					color: root.drag && root.inside(box) ? Config.settingsSelected : Config.settingsCard

					Text {
						id: slotTitle

						anchors.left: parent.left
						anchors.leftMargin: Config.settingsGap
						y: Config.settingsGap / 2
						height: Config.settingsChipHeight
						verticalAlignment: Text.AlignVCenter
						width: 64
						elide: Text.ElideRight
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsFontSize
						color: Config.settingsLabel
						text: root.title(slot.name)
					}

					Flow {
						id: chips

						anchors.left: slotTitle.right
						anchors.leftMargin: Config.settingsGap
						anchors.right: parent.right
						anchors.rightMargin: Config.settingsGap
						y: Config.settingsGap / 2
						spacing: 6

						Repeater {
							id: chipRepeater

							model: root.layout[slot.name] || []

							delegate: Rectangle {
								id: chip

								required property var modelData
								required property int index

								width: chipRow.width + 16
								height: Config.settingsChipHeight
								radius: height / 2
								color: Config.launcherHighlight
								opacity: root.drag && root.drag.from === slot.name && root.drag.index === chip.index ? 0.3 : 1

								Row {
									id: chipRow

									anchors.centerIn: parent
									spacing: 6

									Glyph {
										width: 14
										height: Config.settingsChipHeight
										size: Config.settingsFontSize
										glyph: root.glyphOf(chip.modelData.id)
									}

									Text {
										anchors.verticalCenter: parent.verticalCenter
										font.family: Config.fontFamily
										font.pixelSize: Config.settingsFontSize
										color: Config.foreground
										text: root.title(chip.modelData.id)
									}
								}

								MouseArea {
									anchors.fill: parent
									cursorShape: Qt.OpenHandCursor
									preventStealing: true
									onPressed: function (mouse) { root.begin(slot.name, chip.index, chip.modelData.id, chip, mouse); }
									onPositionChanged: function (mouse) { root.follow(chip, mouse); }
									onReleased: root.finish()
									onCanceled: root.drag = null
								}
							}
						}
					}
				}
			}
		}

		Text {
			topPadding: Config.settingsGap
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			font.letterSpacing: 1
			color: Config.settingsLabel
			text: "WIDGETS"
		}

		Rectangle {
			id: libraryBox

			width: parent.width
			height: libraryColumn.height + Config.settingsGap
			radius: Config.settingsRadius
			color: root.drag && root.drag.from && root.inside(libraryBox) ? Config.settingsSelected : Config.settingsCard

			Column {
				id: libraryColumn

				x: Config.settingsGap
				y: Config.settingsGap / 2
				width: parent.width - Config.settingsGap * 2

				Repeater {
					model: root.library

					delegate: Item {
						id: feature

						required property var modelData

						readonly property bool placed: Toml.placed(root.store.layout, feature.modelData.id)

						width: libraryColumn.width
						height: Config.settingsRowHeight
						opacity: feature.placed ? 0.35 : 1

						Glyph {
							id: featureGlyph

							anchors.verticalCenter: parent.verticalCenter
							width: 20
							height: 20
							size: Config.settingsFontSize + 2
							glyph: Config.glyph(feature.modelData.glyph)
						}

						Text {
							id: featureName

							anchors.left: featureGlyph.right
							anchors.leftMargin: Config.settingsGap
							anchors.verticalCenter: parent.verticalCenter
							width: 110
							elide: Text.ElideRight
							font.family: Config.fontFamily
							font.pixelSize: Config.settingsFontSize
							color: Config.foreground
							text: root.title(feature.modelData.id)
						}

						Text {
							anchors.left: featureName.right
							anchors.leftMargin: Config.settingsGap
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							elide: Text.ElideRight
							font.family: Config.fontFamily
							font.pixelSize: Config.settingsSmallSize
							color: Config.settingsLabel
							text: feature.modelData.description || ""
						}

						MouseArea {
							anchors.fill: parent
							enabled: !feature.placed
							cursorShape: Qt.OpenHandCursor
							preventStealing: true
							onPressed: function (mouse) { root.begin(null, -1, feature.modelData.id, feature, mouse); }
							onPositionChanged: function (mouse) { root.follow(feature, mouse); }
							onReleased: root.finish()
							onCanceled: root.drag = null
						}
					}
				}
			}
		}
	}

	Rectangle {
		visible: root.drag !== null
		z: 10
		x: root.drag ? root.drag.x - ghostRow.width / 2 - 8 : 0
		y: root.drag ? root.drag.y - height / 2 : 0
		width: ghostRow.width + 16
		height: Config.settingsChipHeight
		radius: height / 2
		color: Config.settingsAccent

		Row {
			id: ghostRow

			anchors.centerIn: parent
			spacing: 6

			Glyph {
				width: 14
				height: Config.settingsChipHeight
				size: Config.settingsFontSize
				color: Config.surface
				glyph: root.drag ? root.glyphOf(root.drag.id) : ""
			}

			Text {
				anchors.verticalCenter: parent.verticalCenter
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize
				color: Config.surface
				text: root.drag ? root.title(root.drag.id) : ""
			}
		}
	}
}
