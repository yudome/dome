import QtQuick
import QtQuick.Shapes
import qs
import qs.services

Item {
	id: root

	property var model: []
	property int selected: -1
	property real level: -1
	property int cursor: -1
	property bool vertical: false
	property color ink: Config.foreground
	property color track: Config.dim
	property real gap: Config.stepBarGap
	property var formatter: null
	property real hitPad: 0
	property var onPick
	property bool follow: true
	property bool circular: false
	property bool lens: true
	property real ringWidth: Config.stepBarHeight
	property var glyph: null
	property bool animated: false
	property real tick: 0

	readonly property int count: root.model.length
	readonly property real ringSize: Math.min(root.width, root.height)
	readonly property real ringRadius: Math.max(0, root.ringSize / 2 - root.ringWidth / 2)
	readonly property real cellSize: root.count > 0 ? ((root.vertical ? root.height : root.width) - (root.count - 1) * root.gap) / root.count : 0
	readonly property int hovered: root.follow && bar.containsMouse && root.count > 0 ? root.indexAt(bar.mouseX, bar.mouseY) : -1
	readonly property int hoverRank: root.hovered < 0 ? -1 : root.vertical ? root.count - 1 - root.hovered : root.hovered
	readonly property int shown: root.hoverRank >= 0 ? root.hoverRank : root.selected
	readonly property string hoverLabel: root.entryLabel(root.hovered)
	readonly property bool solid: root.level >= 0
	readonly property real filled: Calc.clamp(root.level, 0, 1)
	readonly property real thickness: root.vertical ? root.width : root.height
	readonly property real lensSize: root.thickness + Config.stepBarLensPad * 2
	readonly property bool glyphs: root.glyph !== null
	readonly property real cellWidth: Math.max(1, glyphFont.advanceWidth("#"))
	readonly property int cols: Math.floor((root.width - Config.stepBarLensPad * 2) / root.cellWidth)
	readonly property int filledCols: root.shown < 0 ? 0 : Calc.clamp(Math.floor((root.lensAt - root.knobHalf - Config.stepBarLensPad) / root.cellWidth), 0, root.cols)
	readonly property real knobHalf: root.glyphs ? Config.stepBarKnobWidth / 2 : root.lensSize / 2
	readonly property real lensAt: {
		const slot = root.vertical ? root.count - 1 - root.shown : root.shown;
		const edge = slot * (root.cellSize + root.gap) + (root.vertical ? 0 : root.cellSize);
		return Calc.clamp(edge, root.knobHalf, (root.vertical ? root.height : root.width) - root.knobHalf);
	}

	implicitHeight: root.glyphs ? Config.stepBarGlyphSize * 2 + Config.stepBarLensPad * 2 : Config.stepBarHeight

	function glyphRow(r) {
		const value = root.shown >= 0 ? root.valueOf(root.model[root.shown]) : null;
		let out = "";
		for (let c = 0; c < root.filledCols; c++)
			out += root.glyph(c, r, root.filledCols, root.tick, value, root.model);
		return out;
	}

	function edge(k) {
		return k * (root.cellSize + root.gap) - root.gap / 2;
	}

	function indexAt(x, y) {
		const at = root.vertical ? y : x;
		const slot = Math.floor(at / (root.cellSize + root.gap));

		return Calc.clamp(slot, 0, root.count - 1);
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

	Rectangle {
		visible: root.solid && !root.circular
		anchors.fill: parent
		color: root.track
	}

	Rectangle {
		visible: root.solid && !root.circular
		anchors.bottom: parent.bottom
		anchors.left: parent.left
		width: root.vertical ? root.width : root.width * root.filled
		height: root.vertical ? root.height * root.filled : root.height
		color: root.ink
	}

	Rectangle {
		visible: root.solid && root.circular
		anchors.centerIn: parent
		width: root.ringSize
		height: root.ringSize
		radius: root.ringSize / 2
		color: "transparent"
		border.width: root.ringWidth
		border.color: root.track
		antialiasing: true
	}

	Shape {
		visible: root.solid && root.circular && root.filled > 0
		anchors.centerIn: parent
		width: root.ringSize
		height: root.ringSize
		preferredRendererType: Shape.CurveRenderer
		asynchronous: false
		antialiasing: true

		ShapePath {
			fillColor: "transparent"
			strokeColor: root.ink
			strokeWidth: root.ringWidth
			capStyle: ShapePath.RoundCap

			PathAngleArc {
				centerX: root.ringSize / 2
				centerY: root.ringSize / 2
				radiusX: root.ringRadius
				radiusY: root.ringRadius
				startAngle: -90
				sweepAngle: root.filled * 359.99
				moveToStart: true
			}
		}
	}

	FontMetrics {
		id: glyphFont

		font.family: Config.fontFamily
		font.pixelSize: Config.stepBarGlyphSize
	}

	Timer {
		interval: Config.stepBarGlyphTick
		repeat: true
		running: root.visible && root.glyphs && root.animated

		onTriggered: root.tick += interval / 1000
	}

	Rectangle {
		visible: root.glyphs && !root.vertical
		anchors.fill: parent
		color: Qt.rgba(root.track.r, root.track.g, root.track.b, Config.stepBarGlyphTrack)
	}

	Rectangle {
		visible: root.glyphs && !root.vertical && root.shown >= 0
		width: root.lensAt
		height: root.height
		color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, Config.stepBarGlyphFill)
	}

	Repeater {
		model: root.glyphs && !root.vertical ? Math.max(0, root.count - 1) * 2 : 0

		delegate: Rectangle {
			required property int index

			readonly property int boundary: Math.floor(index / 2) + 1

			x: root.edge(boundary) - width / 2
			y: index % 2 === 0 ? 0 : root.height - height
			width: 2
			height: Config.stepBarLensPad
			color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, Config.stepBarGlyphFill * 3)
		}
	}

	Repeater {
		model: root.glyphs && !root.vertical ? 2 : 0

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
		id: bar

		anchors.fill: parent
		anchors.topMargin: root.vertical ? 0 : -root.hitPad
		anchors.bottomMargin: root.vertical ? 0 : -root.hitPad
		anchors.leftMargin: root.vertical ? -root.hitPad : 0
		anchors.rightMargin: root.vertical ? -root.hitPad : 0
		acceptedButtons: Qt.NoButton
		hoverEnabled: true
	}

	Grid {
		visible: !root.solid
		columns: Math.max(1, root.vertical ? 1 : root.count)
		rowSpacing: root.gap
		columnSpacing: root.gap

		Repeater {
			model: root.model

			delegate: Rectangle {
				id: segment

				required property var modelData
				required property int index

				readonly property int rank: root.vertical ? root.count - 1 - segment.index : segment.index

				width: root.vertical ? root.width : root.cellSize
				height: root.vertical ? root.cellSize : root.height
				color: root.glyphs ? "transparent" : segment.rank <= root.selected ? root.ink : root.track

				Behavior on color {
					ColorAnimation {
						duration: 120
						easing.type: Easing.OutCubic
					}
				}

				Highlight {
					active: root.cursor === segment.index
				}

				MouseArea {
					anchors.fill: parent

					onClicked: root.pick(segment.modelData)
				}
			}
		}
	}

	Rectangle {
		id: lensMark

		readonly property real size: root.lensSize + 4

		z: 2
		width: root.glyphs ? Config.stepBarKnobWidth : size
		height: root.glyphs ? root.height + 4 : size
		radius: root.glyphs ? Config.stepBarGlyphRadius : size / 2
		color: root.glyphs ? Config.foreground : root.ink
		border.width: 2
		border.color: root.glyphs ? root.ink : Config.surface
		antialiasing: true
		visible: root.lens && !root.solid && root.shown >= 0
		x: root.vertical ? (root.width - width) / 2 : root.lensAt - width / 2
		y: root.vertical ? root.lensAt - height / 2 : (root.height - height) / 2

		Rectangle {
			visible: root.glyphs
			anchors.centerIn: parent
			width: 2
			height: parent.height * 0.4
			radius: 1
			color: Config.dim
		}

		Behavior on x {
			NumberAnimation {
				duration: 120
				easing.type: Easing.OutCubic
			}
		}

		Behavior on y {
			NumberAnimation {
				duration: 120
				easing.type: Easing.OutCubic
			}
		}
	}
}
