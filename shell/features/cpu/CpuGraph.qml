import QtQuick
import qs
import qs.ui

Item {
	id: root

	property var history: []
	property var cores: []
	property color ink: Config.cpuBase

	readonly property int dot: Math.max(1, Math.round(Config.cpuDotPitch * 0.6))
	readonly property real pitch: Config.cpuDotPitch
	readonly property int rows: Math.floor(Config.cpuGraphHeight / root.pitch)
	readonly property int coreRows: Math.floor(Config.cpuBarsHeight / root.pitch)
	readonly property real step: root.width / Math.max(1, Config.cpuGraphSamples)
	readonly property real slot: root.cores.length > 0 ? root.width / root.cores.length : 0
	readonly property int coreCols: root.cores.length > 0 ? Math.max(1, Math.floor((root.slot - Config.gapsIn) / root.pitch)) : 1
	readonly property real grid: root.coreCols * root.pitch
	readonly property real offset: (root.pitch - root.dot) / 2
	readonly property real barsY: Config.cpuGraphHeight + Config.gapsOut
	readonly property int shift: Config.cpuGraphSamples - root.history.length

	implicitHeight: root.barsY + Config.cpuBarsHeight

	Repeater {
		model: Config.cpuGraphSamples * root.rows

		delegate: Rectangle {
			required property int index

			readonly property int column: Math.floor(index / root.rows)
			readonly property int row: index % root.rows
			readonly property int sample: column - root.shift
			readonly property real value: sample >= 0 && sample < root.history.length ? root.history[sample] : 0
			readonly property int lit: Math.round(Math.min(1, Math.max(0, value / 100)) * root.rows)

			x: Math.round(root.width - (Config.cpuGraphSamples - column) * root.step + (root.step - root.dot) / 2)
			y: Math.round(Config.cpuGraphHeight - (row + 1) * root.pitch + root.offset)
			width: root.dot
			height: root.dot
			antialiasing: false
			visible: sample >= 0 && row < lit
			color: root.ink
		}
	}

	Repeater {
		model: root.cores.length

		delegate: Rectangle {
			required property int index

			x: Math.round(index * root.slot + (root.slot - root.grid) / 2)
			y: root.barsY
			width: Math.round(root.grid)
			height: Config.cpuBarsHeight
			color: Config.cpuIdle
		}
	}

	Repeater {
		model: root.cores.length * root.coreCols * root.coreRows

		delegate: Rectangle {
			required property int index

			readonly property int per: root.coreCols * root.coreRows
			readonly property int core: Math.floor(index / per)
			readonly property int rest: index % per
			readonly property int column: Math.floor(rest / root.coreRows)
			readonly property int row: rest % root.coreRows
			readonly property real value: core < root.cores.length ? root.cores[core] : 0
			readonly property int lit: Math.round(Math.min(1, Math.max(0, value / 100)) * root.coreRows)
			readonly property real origin: core * root.slot + (root.slot - root.grid) / 2

			x: Math.round(origin + column * root.pitch + root.offset)
			y: Math.round(root.barsY + Config.cpuBarsHeight - (row + 1) * root.pitch + root.offset)
			width: root.dot
			height: root.dot
			antialiasing: false
			visible: row < lit
			color: root.ink
		}
	}
}
