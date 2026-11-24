pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.services

Item {
	id: root

	property var value
	property real normalized: 0
	property bool dragging: false
	property bool hovered: false
	property int orientation: Qt.Horizontal
	property var stops: []
	property color ink: Config.foreground
	property bool animated: false
	property var glyph: function (c, r, n) { return "#"; }
	property real tick: 0

	readonly property int count: root.stops ? root.stops.length : 0
	readonly property real knobHalf: Config.stepBarKnobWidth / 2
	readonly property real knobAt: root.knobHalf + root.normalized * (root.width - Config.stepBarKnobWidth)
	readonly property real cellWidth: Math.max(1, glyphFont.advanceWidth("#"))
	readonly property int cols: Math.max(0, Math.floor((root.width - Config.stepBarLensPad * 2) / root.cellWidth))
	readonly property int filledCols: Calc.clamp(Math.floor((root.knobAt - root.knobHalf - Config.stepBarLensPad) / root.cellWidth), 0, root.cols)
	readonly property real boxHeight: Config.stepBarGlyphSize * 2 + Config.stepBarLensPad * 2

	implicitWidth: Config.appControlWidth
	implicitHeight: root.boxHeight + Config.stepBarDotGap + Config.stepBarDot

	function stopValue(entry) {
		return entry !== null && entry !== undefined && entry.value !== undefined ? entry.value : entry;
	}

	function glyphRow(r) {
		const options = (root.stops || []).map(root.stopValue);
		let out = "";
		for (let c = 0; c < root.filledCols; c++)
			out += root.glyph(c, r, root.filledCols, root.tick, root.value, options);
		return out;
	}

	function stopX(i) {
		return root.knobHalf + (root.count > 1 ? i / (root.count - 1) : 0) * (root.width - Config.stepBarKnobWidth);
	}

	FontMetrics {
		id: glyphFont

		font.family: Config.fontFamily
		font.pixelSize: Config.stepBarGlyphSize
	}

	Timer {
		interval: Config.stepBarGlyphTick
		repeat: true
		running: root.visible && root.animated
		onTriggered: root.tick += interval / 1000
	}

	Rectangle {
		width: root.width
		height: root.boxHeight
		color: Qt.darker(Config.surface, Config.stepBarGlyphShade)
	}

	Rectangle {
		width: root.knobAt
		height: root.boxHeight
		color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, Config.stepBarGlyphFill)
	}

	Repeater {
		model: root.count

		delegate: Rectangle {
			required property int index

			x: root.stopX(index) - width / 2
			y: root.boxHeight + Config.stepBarDotGap
			width: Config.stepBarDot
			height: Config.stepBarDot
			radius: Config.stepBarDot / 2
			color: root.stopX(index) <= root.knobAt + 0.5 ? root.ink : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, Config.stepBarGlyphFill * 4)
		}
	}

	Repeater {
		model: 2

		delegate: Text {
			required property int index

			x: Config.stepBarLensPad
			y: Config.stepBarLensPad + index * Config.stepBarGlyphSize
			width: root.filledCols * root.cellWidth
			height: Config.stepBarGlyphSize
			verticalAlignment: Text.AlignVCenter
			elide: Text.ElideRight
			font: glyphFont.font
			color: root.ink
			text: root.glyphRow(index)
		}
	}

	Rectangle {
		x: root.knobAt - width / 2
		y: -Config.stepBarLensPad
		width: Config.stepBarKnobWidth
		height: root.boxHeight + Config.stepBarLensPad * 2
		radius: Config.stepBarGlyphRadius
		color: Config.foreground
		border.width: root.dragging ? Config.stepBarLensPad : Config.stepBarGap
		border.color: root.ink
		scale: root.dragging || root.hovered ? 1.15 : 1
		antialiasing: true

		Rectangle {
			anchors.centerIn: parent
			width: Config.stepBarGap
			height: parent.height * 0.4
			radius: width / 2
			color: Config.dim
		}

		Behavior on scale {
			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}

		Behavior on x {
			enabled: !root.dragging

			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}
	}
}
