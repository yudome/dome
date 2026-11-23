pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.services
import qs.ui
import qs.appkit

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

	function glyphOf(id) {
		const info = root.store.features[id];
		return info ? info.glyph : "";
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

	Column {
		id: column

		width: parent.width
		spacing: Metrics.sectionGap

		AppSection {
			title: "Layout"

			Repeater {
				model: root.slotNames

				delegate: Item {
					id: slot

					required property string modelData
					required property int index

					readonly property string name: modelData

					Component.onCompleted: root.targets[slot.index] = { name: slot.name, area: box, flow: chips, list: chipRepeater }

					width: parent.width
					height: Math.max(Metrics.rowHeight + Metrics.gapSmall * 2, chips.height + Metrics.gap + Metrics.gapSmall * 2)

					Item {
						id: box

						y: Metrics.gapSmall
						width: parent.width
						height: parent.height - Metrics.gapSmall * 2
					}

					Rectangle {
						z: 2
						visible: root.hoverSlot === slot.name && root.drag !== null
						x: {
							if (root.hoverIndex < 0 || chipRepeater.count === 0)
								return chips.x;
							if (root.hoverIndex >= chipRepeater.count) {
								const last = chipRepeater.itemAt(chipRepeater.count - 1);
								return last ? last.x + last.width + chips.x + Metrics.border * 3 : chips.x;
							}
							const at = chipRepeater.itemAt(root.hoverIndex);
							return at ? at.x + chips.x - Metrics.border * 3 : chips.x;
						}
						y: chips.y + Metrics.border * 2
						width: Metrics.border * 2
						height: Metrics.chipHeight - Metrics.border * 4
						radius: width / 2
						color: AppPalette.ink
					}

					Separator {
						visible: slot.index < 2
						anchors.bottom: parent.bottom
						width: parent.width
						color: AppPalette.rule
					}

					Label {
						id: slotTitle

						anchors.verticalCenter: parent.verticalCenter
						width: Metrics.leading * 2.5
						text: root.title(slot.name)
					}

					Flow {
						id: chips

						anchors.left: slotTitle.right
						anchors.leftMargin: Metrics.gap
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						spacing: Metrics.gapSmall * 1.5

						Repeater {
							id: chipRepeater

							model: root.layout[slot.name] || []

							delegate: Chip {
								id: chip

								required property var modelData
								required property int index

								hoverable: false
								hot: chipDrag.containsMouse
								icon: root.glyphOf(chip.modelData.id)
								text: root.title(chip.modelData.id)
								opacity: root.drag && root.drag.from === slot.name && root.drag.index === chip.index ? Metrics.disabled : 1

								MouseArea {
									id: chipDrag

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

		AppSection {
			id: libraryBox

			title: "Widgets"

			Repeater {
				model: root.available

				delegate: ListRow {
					id: feature

					required property var modelData
					required property int index

					width: parent.width
					height: Metrics.rowHeight
					inset: 0
					rule: feature.index < root.available.length - 1
					selected: root.hoverSlot === "library" && root.drag !== null
					icon: feature.modelData.glyph
					title: root.title(feature.modelData.id)
					subtitle: feature.modelData.description || ""

					MouseArea {
						parent: feature
						anchors.fill: parent
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

	Chip {
		visible: root.drag !== null
		z: 10
		x: root.drag ? root.drag.x - width / 2 : 0
		y: root.drag ? root.drag.y - height / 2 : 0
		hoverable: false
		hot: true
		icon: root.drag ? root.glyphOf(root.drag.id) : ""
		text: root.drag ? root.title(root.drag.id) : ""
	}
}
