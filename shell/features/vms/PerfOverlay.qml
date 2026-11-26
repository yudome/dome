import QtQuick
import qs
import qs.ui
import qs.appkit

Rectangle {
	id: root

	property var stats: ({})

	readonly property real lineWidth: Metrics.captionSize * 18

	function ms(value) {
		return value === undefined ? "-" : value < 10 ? value.toFixed(2) : value.toFixed(1);
	}

	readonly property var lines: [
		root.stats.width ? root.stats.width + "x" + root.stats.height : "no guest frame yet",
		"fps " + (root.stats.fps || 0) + "  shown " + (root.stats.shownFps || 0),
		"frame " + root.ms(root.stats.frameNow) + "  avg " + root.ms(root.stats.frameAvg) + " ms",
		"p99 " + root.ms(root.stats.frameP99) + "  max " + root.ms(root.stats.frameMax) + " ms",
		"recv>screen " + root.ms(root.stats.latency) + " ms",
		root.stats.flipRecv === undefined ? "" : "flip>recv " + root.ms(root.stats.flipRecv) + " ms",
		root.stats.flipScreen === undefined ? "" : "flip>screen " + root.ms(root.stats.flipScreen) + " ms",
		"input " + (root.stats.inputPs || 0) + "/s",
		root.stats.path || ""
	]

	width: root.lineWidth + Metrics.gapSmall * 4
	height: column.implicitHeight + Metrics.gapSmall * 3
	radius: Metrics.radius
	color: Config.surfaceRaised
	opacity: 0.9

	Column {
		id: column

		x: Metrics.gapSmall * 2
		y: Metrics.gapSmall * 1.5
		width: root.lineWidth

		Repeater {
			model: root.lines.filter(line => line !== "")

			delegate: Label {
				required property string modelData

				width: column.width
				role: "value"
				horizontalAlignment: Text.AlignLeft
				font.pixelSize: Metrics.captionSize
				text: modelData
			}
		}
	}
}
