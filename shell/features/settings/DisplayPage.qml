pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit
import qs.services

Column {
	id: root

	required property var store

	readonly property var monitor: root.store.monitor
	readonly property bool ready: root.monitor !== null && root.monitor !== undefined
	readonly property var groups: root.store.screenGroups
	readonly property var resolutions: root.ready ? root.monitor.resolutions || [] : []
	readonly property int shortList: 8
	readonly property bool more: root.resolutions.length > root.shortList
	property bool open: false

	spacing: Metrics.sectionGap

	function density(c, r, n) {
		const ramp = " .-+xXS#";
		const k = Math.floor((c + 0.5) / n * (ramp.length - 1) - (r === 1 ? 1.2 : 0) + Calc.hash(c, r, 0) * 0.8);
		return ramp[Calc.clamp(k, 1, ramp.length - 1)];
	}

	function wave(c, r, n, t, value, options) {
		const ramp = " .-+xXS#";
		const top = Math.max.apply(null, options.map(Number));
		const rank = top > 0 ? Number(value) / top : 0;
		const gap = Math.round(18 - rank * 10);
		const head = Math.floor(t * (6 + rank * 30));
		const behind = (((head - c - r) % gap) + gap) % gap;
		return ramp[Math.max(0, ramp.length - 1 - behind)];
	}

	function format(kind, value) {
		if (kind === "scale" && value !== "" && isFinite(Number(value)))
			return Number(value).toFixed(2);
		if (kind === "refresh" && value !== "" && String(value).indexOf("Hz") < 0)
			return value + " Hz";
		return String(value);
	}

	AppSection {
		title: "Monitor"

		FormRow {
			width: parent.width
			label: root.ready ? (root.monitor.name || "") + (root.monitor.description ? "  " + root.monitor.description : "") : Config.displayNothing
			note: root.ready ? root.monitor.width + "x" + root.monitor.height + "  " + Math.round(root.monitor.refresh) + " Hz" : ""
			last: root.groups.length === 0

			Button {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				icon: "refresh"
				text: "Detect"
				onClicked: root.store.detectScreen()
			}
		}

		Repeater {
			model: root.groups

			delegate: FormRow {
				id: group

				required property var modelData
				required property int index

				width: parent.width
				label: group.modelData.label
				last: group.index === root.groups.length - 1
				controlHeight: bar.implicitHeight

				Slider {
					id: bar

					anchors.left: parent.left
					anchors.right: valueLabel.left
					anchors.rightMargin: Metrics.gap
					anchors.verticalCenter: parent.verticalCenter
					label: group.modelData.label
					stops: group.modelData.options
					value: bar.stopValue(group.modelData.options[group.modelData.selected])
					onMoved: function (next) { root.store.pickScreen(group.modelData.kind, next); }

					renderer: Component {
						GlyphScale {
							glyph: group.modelData.kind === "refresh" ? root.wave : root.density
							animated: group.modelData.kind === "refresh"
						}
					}
				}

				Label {
					id: valueLabel

					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					width: Metrics.chipHeight * 2
					role: "value"
					text: root.format(group.modelData.kind, bar.dragging ? bar.shownValue : group.modelData.shown)
				}
			}
		}
	}

	AppSection {
		visible: root.resolutions.length > 0
		title: "Resolution"

		Repeater {
			model: root.open ? root.resolutions : root.resolutions.slice(0, root.shortList)

			delegate: ListRow {
				id: mode

				required property var modelData
				required property int index

				readonly property bool inUse: root.ready && mode.modelData.width === root.monitor.width && mode.modelData.height === root.monitor.height

				width: parent.width
				height: Metrics.rowHeight - Metrics.gapSmall
				inset: 0
				hoverable: true
				rule: mode.index < (root.open ? root.resolutions.length : Math.min(root.shortList, root.resolutions.length)) - 1 || root.more
				dim: !mode.inUse
				title: mode.modelData.label
				onActivated: root.store.pickScreen("resolution", mode.modelData.label)

				Label {
					anchors.verticalCenter: parent.verticalCenter
					role: "caption"
					text: mode.modelData.maxRefresh > 0 ? mode.modelData.maxRefresh + " Hz" : ""
				}

				Icon {
					anchors.verticalCenter: parent.verticalCenter
					width: Metrics.bodySize
					height: Metrics.bodySize
					size: Metrics.bodySize
					name: mode.inUse ? "check" : ""
				}
			}
		}

		Item {
			width: parent.width
			height: root.more ? Metrics.rowHeight - Metrics.gapSmall : 0
			visible: root.more

			Button {
				anchors.left: parent.left
				anchors.leftMargin: -Metrics.gap
				anchors.verticalCenter: parent.verticalCenter
				kind: "ghost"
				text: root.open ? "Fewer resolutions" : "More resolutions"
				onClicked: root.open = !root.open
			}
		}
	}
}
