pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.services
import qs.ui
import "../../bar"

Item {
	id: root

	required property var store
	required property var library

	readonly property var layout: root.store.layout ? root.store.layout.bar.layout : ({ left: [], center: [], right: [] })
	readonly property var slotNames: ["left", "center", "right"]
	property var drag: null
	property var targets: []
	property string hoverSlot: ""
	property int hoverIndex: -1

	width: parent ? parent.width : 0
	height: column.height

	readonly property var names: ({ cpu: "CPU", github: "GitHub" })
	readonly property var available: root.library.filter(function (f) { return f.id === "spacer" || !root.placed(root.store.layout, f.id); })

	function title(id) {
		return root.names[id] || id.charAt(0).toUpperCase() + id.slice(1);
	}

	function copy(doc) {
		const out = JSON.parse(JSON.stringify(doc || {}));
		out.version = out.version || 1;
		out.bar = out.bar || {};
		out.bar.layout = out.bar.layout || {};
		root.slotNames.forEach(function (slot) {
			out.bar.layout[slot] = (out.bar.layout[slot] || []).filter(function (e) { return e && e.id; });
		});
		return out;
	}

	function placed(doc, id) {
		const layout = root.copy(doc).bar.layout;
		return root.slotNames.some(function (slot) {
			return layout[slot].some(function (e) { return e.id === id; });
		});
	}

	function move(doc, fromSlot, fromIndex, toSlot, toIndex) {
		const out = root.copy(doc);
		const layout = out.bar.layout;
		const entry = fromSlot ? layout[fromSlot].splice(fromIndex, 1)[0] : { id: fromIndex };
		if (!entry || (!fromSlot && entry.id !== "spacer" && root.placed(out, entry.id)))
			return out;
		if (fromSlot === toSlot && toIndex > fromIndex)
			toIndex -= 1;
		if (toSlot)
			layout[toSlot].splice(Math.max(0, Math.min(toIndex, layout[toSlot].length)), 0, entry);
		if (!root.placed(out, out.bar.centerAnchor))
			out.bar.centerAnchor = layout.center.length > 0 ? layout.center[0].id : "";
		return out;
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
		root.aim(at.x, at.y);
	}

	function insideAt(target, x, y) {
		const at = target.mapFromItem(root, x, y);
		return at.x >= 0 && at.y >= 0 && at.x <= target.width && at.y <= target.height;
	}

	function indexAt(slot, x, y) {
		const p = slot.flow.mapFromItem(root, x, y);
		const count = slot.list.count;
		if (count === 0)
			return 0;

		let rowY = null;
		for (let i = 0; i < count; i++) {
			const c = slot.list.itemAt(i);
			if (c && p.y >= c.y - 1 && p.y <= c.y + c.height + 1) {
				rowY = c.y;
				break;
			}
		}
		const first = slot.list.itemAt(0);
		const last = slot.list.itemAt(count - 1);
		if (rowY === null)
			rowY = p.y < first.y ? first.y : last.y;

		let index = count;
		for (let i = 0; i < count; i++) {
			const c = slot.list.itemAt(i);
			if (!c || Math.abs(c.y - rowY) > 2)
				continue;
			if (index === count)
				index = i;
			if (c.x + c.width / 2 < p.x)
				index = i + 1;
		}
		return index;
	}

	function aim(x, y) {
		root.hoverSlot = "";
		root.hoverIndex = -1;
		if (x === undefined)
			return;
		for (let s = 0; s < root.targets.length; s++) {
			const slot = root.targets[s];
			if (!root.insideAt(slot.area, x, y))
				continue;
			root.hoverSlot = slot.name;
			root.hoverIndex = root.indexAt(slot, x, y);
			return;
		}
		if (root.insideAt(libraryBox, x, y))
			root.hoverSlot = "library";
	}

	function finish() {
		const d = root.drag;
		if (!d) {
			root.drag = null;
			return;
		}

		root.aim(d.x, d.y);
		const slot = root.hoverSlot;
		const index = root.hoverIndex;
		root.drag = null;
		root.hoverSlot = "";
		root.hoverIndex = -1;

		if (slot !== "" && slot !== "library")
			root.store.setLayout(root.move(root.store.layout, d.from, d.from ? d.index : d.id, slot, index));
		else if (slot === "library" && d.from)
			root.store.setLayout(root.move(root.store.layout, d.from, d.index, null, 0));
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

							Item {
								id: box

								x: 0
								y: 4
								width: parent.width
								height: parent.height - 8
							}

							Rectangle {
								z: 2
								visible: root.hoverSlot === slot.name && root.drag !== null
								x: {
									if (root.hoverIndex < 0 || chipRepeater.count === 0)
										return chipRepeater.count === 0 ? chips.x : chips.x;
									if (root.hoverIndex >= chipRepeater.count) {
										const last = chipRepeater.itemAt(chipRepeater.count - 1);
										return last ? last.x + last.width + chips.x + 3 : chips.x;
									}
									const at = chipRepeater.itemAt(root.hoverIndex);
									return at ? at.x + chips.x - 3 : chips.x;
								}
								y: chips.y + 2
								width: 2
								height: Config.settingsChipHeight - 4
								radius: 1
								color: Config.foreground
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

											WidgetGlyph {
												widgetId: chip.modelData.id
												templates: templates
												slot: Config.settingsChipHeight - 8
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

			BarBody {
				id: templates

				visible: false
				width: 1
				height: 1
				sample: true
			}

			Rectangle {
				id: libraryBox

				y: libraryHeading.height + 12
				width: parent.width
				height: libraryColumn.height
				radius: Config.settingsRadius
				color: root.hoverSlot === "library" && root.drag !== null ? Config.settingsSelected : Config.settingsCard

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
						model: root.available

						delegate: Item {
							id: feature

							required property var modelData
							required property int index

							width: libraryColumn.width
							height: Config.settingsRowHeight

							Rectangle {
								visible: feature.index < root.available.length - 1
								anchors.bottom: parent.bottom
								width: parent.width
								height: 1
								color: Config.settingsRule
							}

							WidgetGlyph {
								id: featureGlyph

								anchors.verticalCenter: parent.verticalCenter
								widgetId: feature.modelData.id
								templates: templates
								slot: 22
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
								color: Config.foreground
								text: root.title(feature.modelData.id)
							}

							Text {
								anchors.left: featureName.right
								anchors.leftMargin: Config.settingsGap
								anchors.right: parent.right
								anchors.rightMargin: Config.settingsGap
								anchors.verticalCenter: parent.verticalCenter
								elide: Text.ElideRight
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsSmallSize
								color: Config.settingsLabel
								text: feature.modelData.description || ""
							}

							MouseArea {
								anchors.fill: parent
								enabled: true
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
		color: Config.launcherHighlight

		Row {
			id: ghostRow

			anchors.centerIn: parent
			spacing: 7

			WidgetGlyph {
				widgetId: root.drag ? root.drag.id : ""
				templates: templates
				slot: Config.settingsChipHeight - 6
			}

			Text {
				anchors.verticalCenter: parent.verticalCenter
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize
				color: Config.foreground
				text: root.drag ? root.title(root.drag.id) : ""
			}
		}
	}
}
