import QtQuick
import qs

Item {
	id: root

	property string glyph: ""
	property real size: Config.iconSize
	property color color: Config.foreground
	property bool onBaseline: false

	readonly property real inkWidth: ink.tightBoundingRect.width
	readonly property real inkTop: label.y + label.baselineOffset + ink.tightBoundingRect.y
	readonly property real inkBottom: root.inkTop + ink.tightBoundingRect.height
	readonly property real inkBelow: root.height - root.inkBottom

	implicitWidth: root.size
	implicitHeight: root.size

	TextMetrics {
		id: ink

		font.family: Config.fontFamily
		font.pixelSize: root.size
		text: root.glyph
	}

	Text {
		id: label

		x: (root.width - ink.tightBoundingRect.width) / 2 - ink.tightBoundingRect.x
		y: root.onBaseline ? (root.height - label.height) / 2 : (root.height - ink.tightBoundingRect.height) / 2 - ink.tightBoundingRect.y - label.baselineOffset
		font.family: Config.fontFamily
		font.pixelSize: root.size
		color: root.color
		text: root.glyph
	}
}
