import QtQuick
import qs

Item {
	id: root

	property var value
	property real normalized: 0
	property bool dragging: false
	property bool hovered: false
	property int orientation: Qt.Horizontal
	property var stops: []
	property color ink: Config.foreground
	property color track: Config.dim

	readonly property bool horizontal: root.orientation === Qt.Horizontal
	readonly property real knob: Config.stepBarKnobWidth
	readonly property real line: Config.stepBarDot
	readonly property real travel: (root.horizontal ? root.width : root.height) - root.knob

	implicitWidth: root.horizontal ? Config.appControlWidth : Config.appChipHeight
	implicitHeight: root.horizontal ? Config.appChipHeight : Config.appControlWidth

	Rectangle {
		x: root.horizontal ? root.knob / 2 : (root.width - root.line) / 2
		y: root.horizontal ? (root.height - root.line) / 2 : root.knob / 2
		width: root.horizontal ? root.travel : root.line
		height: root.horizontal ? root.line : root.travel
		radius: root.line / 2
		color: root.track
	}

	Rectangle {
		x: root.horizontal ? root.knob / 2 : (root.width - root.line) / 2
		y: root.horizontal ? (root.height - root.line) / 2 : root.knob / 2 + root.travel * (1 - root.normalized)
		width: root.horizontal ? root.travel * root.normalized : root.line
		height: root.horizontal ? root.line : root.travel * root.normalized
		radius: root.line / 2
		color: root.ink
	}

	Rectangle {
		x: root.horizontal ? root.travel * root.normalized : (root.width - root.knob) / 2
		y: root.horizontal ? (root.height - root.knob) / 2 : root.travel * (1 - root.normalized)
		width: root.knob
		height: root.knob
		radius: root.knob / 2
		color: root.ink
		scale: root.dragging || root.hovered ? 1.15 : 1

		Behavior on scale {
			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}
	}
}
