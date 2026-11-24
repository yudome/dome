import QtQuick
import qs.ui
import qs.panelkit
import qs
import qs.services

ProcessPanel {
	id: root

	readonly property var sys: Yudae.system.cpu || ({})
	readonly property var history: root.sys.graph || []
	readonly property var cores: root.source && root.source.cores ? root.source.cores : []
	readonly property color accentInk: Config.mono ? Config.cpuBaseMono : Config.cpuBase
	readonly property var overview: [
		{ label: "system", text: (root.sys.system || 0).toFixed(2) + "%" },
		{ label: "user", text: (root.sys.user || 0).toFixed(2) + "%" },
		{ label: "idle", text: (root.sys.idle || 0).toFixed(2) + "%" }
	]

	title: root.sys.model || "CPU"
	detail: root.sys.spec || ""
	detailColor: root.accentInk
	totalInk: root.sys.ink || root.accentInk
	contentWidth: Config.cpuTooltipWidth

	viz: [
		Item {
			width: parent.width
			height: graph.implicitHeight

			CpuGraph {
				id: graph

				width: parent.width
				history: root.history
				cores: root.cores
				ink: root.accentInk
			}
		},

		PanelBand {
			width: parent.width
			bleed: root.padding + Config.gapsIn
			ink: root.accentInk
			title: Config.cpuOverviewTitle
		},

		Repeater {
			model: root.overview

			delegate: Item {
				required property var modelData

				width: parent.width
				height: Config.procRowHeight

				Label {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					text: modelData.label
				}

				Label {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					role: "value"
					ink: root.accentInk
					text: modelData.text
				}
			}
		}
	]
}
