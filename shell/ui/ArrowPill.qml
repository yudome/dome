import QtQuick
import qs

Rectangle {
	id: root

	property string glyph: Config.iconChevron
	property string label: ""

	signal clicked()

	implicitWidth: row.implicitWidth + 20
	implicitHeight: Config.toggleHeight + 4
	radius: height / 2
	color: hover.containsMouse ? Config.toggleHover : Config.toggleTrack

	Behavior on color {
		ColorAnimation {
			duration: Config.toggleMs
		}
	}

	Row {
		id: row

		anchors.centerIn: parent
		spacing: 6

		Glyph {
			width: root.height - 10
			height: root.height - 10
			size: Config.toggleFontSize - 2
			color: Config.foreground
			glyph: root.glyph
		}

		Text {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.label !== ""
			font.family: Config.fontFamily
			font.pixelSize: Config.toggleFontSize - 1
			color: Config.foreground
			text: root.label
		}
	}

	MouseArea {
		id: hover

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}
}
