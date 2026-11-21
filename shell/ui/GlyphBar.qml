import QtQuick
import qs
import qs.services

Item {
	id: root

	property var model: []
	property int selected: -1
	property int cursor: -1
	property color ink: Config.foreground
	property var formatter: null
	property var onPick
	property bool follow: true
	property bool animated: false
	required property var glyph
	property real tick: 0
	property int dragged: -1
	property real dragX: -1

	readonly property int count: root.model.length
	readonly property real cellSize: root.count > 0 ? (root.width - (root.count - 1) * Config.stepBarGap) / root.count : 0
	readonly property int hovered: root.follow && hover.containsMouse && root.count > 0 ? root.indexAt(hover.mouseX) : -1
	readonly property int shown: root.dragged >= 0 ? root.dragged : root.hovered >= 0 ? root.hovered : root.selected
	readonly property string hoverLabel: root.entryLabel(root.dragged >= 0 ? root.dragged : root.hovered)
	readonly property real cellWidth: Math.max(1, glyphFont.advanceWidth("#"))
	readonly property int cols: Math.floor((root.width - Config.stepBarLensPad * 2) / root.cellWidth)
	readonly property int filledCols: root.shown < 0 ? 0 : Calc.clamp(Math.floor((root.knobAt - root.knobHalf - Config.stepBarLensPad) / root.cellWidth), 0, root.cols)
	readonly property real knobHalf: Config.stepBarKnobWidth / 2
	readonly property bool dragging: root.dragX >= 0
	readonly property real boxHeight: Config.stepBarGlyphSize * 2 + Config.stepBarLensPad * 2
	readonly property real knobAt: root.dragging ? Calc.clamp(root.dragX, root.knobHalf, root.width - root.knobHalf) : root.stopAt(root.shown)

	onSelectedChanged: root.dragged = -1

	implicitHeight: root.boxHeight + Config.stepBarDotGap + Config.stepBarDot

	function glyphRow(r) {
		const value = root.shown >= 0 ? root.valueOf(root.model[root.shown]) : null;
		let out = "";
		for (let c = 0; c < root.filledCols; c++)
			out += root.glyph(c, r, root.filledCols, root.tick, value, root.model);
		return out;
	}

	function stopAt(slot) {
		return Calc.clamp(slot * (root.cellSize + Config.stepBarGap) + root.cellSize, root.knobHalf, root.width - root.knobHalf);
	}

	function nearest(x) {
		return Calc.clamp(Math.round((x - root.cellSize) / (root.cellSize + Config.stepBarGap)), 0, root.count - 1);
	}

	function indexAt(x) {
		return Calc.clamp(Math.floor(x / (root.cellSize + Config.stepBarGap)), 0, root.count - 1);
	}

	function valueOf(entry) {
		return entry !== null && entry !== undefined && entry.value !== undefined ? entry.value : entry;
	}

	function entryLabel(index) {
		if (index < 0 || index >= root.count)
			return "";

		const entry = root.model[index];
		const label = entry !== null && entry !== undefined && entry.label !== undefined ? String(entry.label) : String(entry);

		return root.formatter !== null ? root.formatter(label) : label;
	}

	function pick(entry) {
		if (root.onPick)
			root.onPick(root.valueOf(entry));
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
		visible: root.shown >= 0
		width: root.knobAt
		height: root.boxHeight
		color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, Config.stepBarGlyphFill)
	}

	Repeater {
		model: root.count

		delegate: Rectangle {
			required property int index

			readonly property bool lit: root.stopAt(index) <= root.knobAt + 0.5

			x: root.stopAt(index) - width / 2
			y: root.boxHeight + Config.stepBarDotGap
			width: Config.stepBarDot
			height: Config.stepBarDot
			radius: Config.stepBarDot / 2
			color: lit ? root.ink : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, Config.stepBarGlyphFill * 4)
		}
	}

	Repeater {
		model: root.count > 0 && root.cursor >= 0 ? 1 : 0

		delegate: Highlight {
			fillParent: false
			x: root.cursor * (root.cellSize + Config.stepBarGap)
			width: root.cellSize
			height: root.boxHeight
		}
	}

	Repeater {
		model: 2

		delegate: Item {
			id: glyphLine

			required property int index

			z: 1
			x: Config.stepBarLensPad
			y: Config.stepBarLensPad + glyphLine.index * Config.stepBarGlyphSize
			width: root.width
			height: Config.stepBarGlyphSize

			Text {
				width: root.filledCols * root.cellWidth
				height: parent.height
				verticalAlignment: Text.AlignVCenter
				elide: Text.ElideRight
				font: glyphFont.font
				color: root.ink
				text: root.glyphRow(glyphLine.index)
			}
		}
	}

	MouseArea {
		id: hover

		anchors.fill: parent
		acceptedButtons: Qt.NoButton
		hoverEnabled: true
	}

	MouseArea {
		z: 3
		anchors.fill: parent
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

		function follow(x) {
			root.dragX = Calc.clamp(x, 0, root.width);
			root.dragged = root.nearest(x);
		}

		onPressed: (mouse) => follow(mouse.x)
		onPositionChanged: (mouse) => follow(mouse.x)
		onCanceled: {
			root.dragX = -1;
			root.dragged = -1;
		}
		onReleased: {
			root.dragX = -1;
			const next = root.dragged;
			if (next === root.selected)
				root.dragged = -1;
			if (next >= 0 && next !== root.selected)
				root.pick(root.model[next]);
		}
	}

	Rectangle {
		z: 2
		visible: root.shown >= 0
		width: Config.stepBarKnobWidth
		height: root.boxHeight + 4
		radius: Config.stepBarGlyphRadius
		color: Config.foreground
		border.width: root.dragging ? 3 : 2
		border.color: root.ink
		scale: root.dragging ? 1.15 : 1
		antialiasing: true
		x: root.knobAt - width / 2
		y: -2

		Behavior on scale {
			NumberAnimation {
				duration: 120
				easing.type: Easing.OutCubic
			}
		}

		Behavior on x {
			enabled: !root.dragging

			NumberAnimation {
				duration: 120
				easing.type: Easing.OutCubic
			}
		}
	}
}
