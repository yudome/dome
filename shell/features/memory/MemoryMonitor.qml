import QtQuick
import qs.ui
import qs.panelkit
import qs
import qs.services

ProcessPanel {
	id: root

	property var mem: root.source ? root.source.memory : null

	readonly property color accentInk: Config.foreground
	readonly property color cachedInk: Config.foreground
	readonly property color buffersInk: Config.foreground
	readonly property var recent: Yudae.system.byMem ? Yudae.system.byMem.slice(0, Config.memoryTopCount) : []

	title: "Memory"
	detail: root.mem ? root.mem.committedText + " of " + root.mem.poolText : ""
	detailColor: root.accentInk
	totalInk: root.mem ? root.mem.ink : root.accentInk
	contentWidth: Config.memoryTooltipWidth

	function usage() {
		const m = root.mem;

		if (!m)
			return [];

		const rows = [
			{ label: "used", text: m.usedText, color: root.totalInk },
			{ label: "cached", text: m.cachedText, color: root.cachedInk },
			{ label: "buffers", text: m.buffersText, color: root.buffersInk }
		];

		if (m.swapUsed > 0)
			rows.push({ label: "swap", text: m.swapUsedText + " of " + m.swapTotalText });

		rows.push({ label: "free", text: m.freeText, color: Config.foreground });

		return rows;
	}

	function segments(breadth) {
		const m = root.mem;

		if (!m || m.pool <= 0)
			return [];

		const divider = m.swapTotal > 0 ? Config.memorySeparator : 0;
		const parts = [
			{ value: m.used, color: root.totalInk },
			{ value: m.cached, color: root.cachedInk },
			{ value: m.buffers, color: root.buffersInk },
			{ value: m.ramFree, color: Config.memoryFree }
		];

		if (divider > 0) {
			parts.push({ value: 0, color: Config.surface, divider: divider });
			parts.push({ value: m.swapUsed, color: Config.memorySwap });
			parts.push({ value: m.swapFree, color: Config.memoryFree });
		}

		const width = breadth - divider;
		let x = 0;

		return parts.map(function (part) {
			const share = part.divider ? part.divider : width * part.value / m.pool;
			const out = {
				x: x,
				width: share,
				color: part.color
			};

			x += out.width;
			return out;
		});
	}

	viz: [
		Item {
			id: vizBar

			width: parent.width
			height: Config.memoryVizHeight
			visible: root.mem !== null

			Repeater {
				model: root.segments(vizBar.width)

				delegate: Rectangle {
					required property var modelData

					x: modelData.x
					width: modelData.width
					height: parent.height
					color: modelData.color
				}
			}
		},

		Repeater {
			model: root.usage()

			delegate: Item {
				required property var modelData

				width: parent.width
				height: Math.max(segmentLabel.implicitHeight, segmentValue.implicitHeight)

				Label {
					id: segmentLabel

					ink: modelData.color || root.accentInk
					text: modelData.label
				}

				Label {
					id: segmentValue

					anchors.right: parent.right

					ink: modelData.color || root.accentInk
					text: modelData.text
				}
			}
		},

		PanelBand {
			width: parent.width
			bleed: root.padding + Config.gapsIn
			ink: root.accentInk
			title: Config.topProcessTitle
		},

		Repeater {
			model: root.recent

			delegate: Item {
				id: cell

				required property var modelData

				readonly property string processIcon: AppIcons.iconOfPid(cell.modelData.pid)

				width: parent.width
				height: Config.procRowHeight

				Item {
					id: iconSlot

					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: Config.launcherIconSize
					height: Config.launcherIconSize

					Icon {
						id: appIcon

						anchors.fill: parent
						size: Config.launcherIconSize
						source: cell.processIcon
						visible: cell.processIcon !== "" && appIcon.status !== Image.Error
					}
				}

				Label {
					anchors.left: iconSlot.right
					anchors.leftMargin: Config.gapsIn * 2
					anchors.right: amount.left
					anchors.rightMargin: Config.gapsIn * 2
					anchors.verticalCenter: parent.verticalCenter
					text: modelData.name
				}

				Label {
					id: amount

					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					role: "value"
					ink: modelData.color || root.accentInk
					text: modelData.valueText
				}
			}
		}
	]
}
