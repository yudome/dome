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

	readonly property var names: ({ cpu: "CPU", github: "GitHub" })
	readonly property var ordered: root.library.filter(function (f) { return !Toml.placed(root.store.layout, f.id); }).concat(root.library.filter(function (f) { return Toml.placed(root.store.layout, f.id); }))

	function title(id) {
		return root.names[id] || id.charAt(0).toUpperCase() + id.slice(1);
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

	component Heading: Text {
		width: root.width
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsFontSize + 3
		color: Config.foreground
	}

	Column {
		id: column

		width: parent.width
		spacing: Config.settingsSectionGap

		Item {
			width: parent.width
			height: slotsHeading.height + 12 + slotsPanel.height

			Heading {
				id: slotsHeading

				text: "Layout"
			}

			Rectangle {
				id: slotsPanel

				y: slotsHeading.height + 12
				width: parent.width
				height: slotColumn.height
				radius: Config.settingsRadius
				color: Config.settingsCard

				Column {
					id: slotColumn

					x: Config.settingsGap + 4
					width: parent.width - x * 2

					Repeater {
						model: root.slotNames

						delegate: Item {
							id: slot

							required property string modelData
							required property int index

							readonly property string name: modelData

							Component.onCompleted: root.targets[slot.index] = { name: slot.name, area: box, flow: chips, list: chipRepeater }

							width: slotColumn.width
							height: Math.max(Config.settingsRowHeight + 8, chips.height + 24)

							Rectangle {
								id: box

								x: -Config.settingsGap + 6
								y: 4
								width: parent.width + (Config.settingsGap - 6) * 2
								height: parent.height - 8
								radius: Config.settingsRadius - 4
								color: Config.settingsSelected
								opacity: root.drag && root.inside(box) ? 1 : 0

								Behavior on opacity {
									NumberAnimation {
										duration: Config.toggleMs
									}
								}
							}

							Rectangle {
								visible: slot.index < 2
								anchors.bottom: parent.bottom
								width: parent.width
								height: 1
								color: Config.settingsRule
							}

							Text {
								id: slotTitle

								anchors.verticalCenter: parent.verticalCenter
								width: 72
								elide: Text.ElideRight
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsFontSize + 1
								color: Config.foreground
								text: root.title(slot.name)
							}

							Text {
								anchors.left: slotTitle.right
								anchors.leftMargin: Config.settingsGap
								anchors.verticalCenter: parent.verticalCenter
								visible: chipRepeater.count === 0
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsSmallSize
								color: Config.settingsLabel
								text: "Empty"
							}

							Flow {
								id: chips

								anchors.left: slotTitle.right
								anchors.leftMargin: Config.settingsGap
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								spacing: 6

								Repeater {
									id: chipRepeater

									model: root.layout[slot.name] || []

									delegate: Rectangle {
										id: chip

										required property var modelData
										required property int index

										width: chipRow.width + 22
										height: Config.settingsChipHeight
										radius: height / 2
										color: chipHover.containsMouse ? Config.toggleHover : Config.launcherHighlight
										opacity: root.drag && root.drag.from === slot.name && root.drag.index === chip.index ? 0.25 : 1

										Row {
											id: chipRow

											anchors.centerIn: parent
											spacing: 7

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
											id: chipHover

											anchors.fill: parent
											hoverEnabled: true
											cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
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
			}
		}

		Item {
			width: parent.width
			height: libraryHeading.height + 12 + libraryBox.height

			Heading {
				id: libraryHeading

				text: "Widgets"
			}

			Rectangle {
				id: libraryBox

				y: libraryHeading.height + 12
				width: parent.width
				height: libraryColumn.height
				radius: Config.settingsRadius
				color: root.drag && root.drag.from && root.inside(libraryBox) ? Config.settingsSelected : Config.settingsCard

				Behavior on color {
					ColorAnimation {
						duration: Config.toggleMs
					}
				}

				Column {
					id: libraryColumn

					x: Config.settingsGap + 4
					width: parent.width - x * 2

					Repeater {
						model: root.ordered

						delegate: Item {
							id: feature

							required property var modelData
							required property int index

							readonly property bool placed: Toml.placed(root.store.layout, feature.modelData.id)

							width: libraryColumn.width
							height: Config.settingsRowHeight

							Rectangle {
								visible: feature.index < root.library.length - 1
								anchors.bottom: parent.bottom
								width: parent.width
								height: 1
								color: Config.settingsRule
							}

							Glyph {
								id: featureGlyph

								anchors.verticalCenter: parent.verticalCenter
								width: 18
								height: 18
								size: Config.settingsFontSize + 1
								color: feature.placed ? Config.settingsLabel : Config.foreground
								glyph: Config.glyph(feature.modelData.glyph)
							}

							Text {
								id: featureName

								anchors.left: featureGlyph.right
								anchors.leftMargin: 14
								anchors.verticalCenter: parent.verticalCenter
								width: 120
								elide: Text.ElideRight
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsFontSize + 1
								color: feature.placed ? Config.settingsLabel : Config.foreground
								text: root.title(feature.modelData.id)
							}

							Text {
								anchors.left: featureName.right
								anchors.leftMargin: Config.settingsGap
								anchors.right: placeMark.left
								anchors.rightMargin: Config.settingsGap
								anchors.verticalCenter: parent.verticalCenter
								elide: Text.ElideRight
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsSmallSize
								color: Config.settingsLabel
								text: feature.modelData.description || ""
							}

							Text {
								id: placeMark

								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: 64
								horizontalAlignment: Text.AlignRight
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsSmallSize
								color: Config.settingsLabel
								text: feature.placed ? "On bar" : ""
							}

							MouseArea {
								anchors.fill: parent
								enabled: !feature.placed
								cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
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
	}

	Rectangle {
		visible: root.drag !== null
		z: 10
		x: root.drag ? root.drag.x - width / 2 : 0
		y: root.drag ? root.drag.y - height / 2 : 0
		width: ghostRow.width + 22
		height: Config.settingsChipHeight
		radius: height / 2
		color: Config.foreground

		Row {
			id: ghostRow

			anchors.centerIn: parent
			spacing: 7

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
