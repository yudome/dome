import QtQuick
import qs

Rectangle {
	id: root

	property real padding: 0
	property real inset: Config.appGap + Config.gapsIn
	property bool selected: false
	property bool hoverable: false

	default property alias content: body.data

	readonly property bool hovered: hit.containsMouse

	signal clicked()

	implicitWidth: Config.appControlWidth
	implicitHeight: body.implicitHeight + root.padding * 2
	radius: Config.appRadius
	color: root.hoverable && hit.containsMouse ? Config.surfaceHover : Config.surfaceRaised

	MouseArea {
		id: hit

		anchors.fill: parent
		visible: root.hoverable
		hoverEnabled: root.hoverable
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}

	Column {
		id: body

		x: root.inset
		y: root.padding
		width: root.width - root.inset * 2
	}

	Rectangle {
		anchors.fill: parent
		z: 1
		radius: root.radius
		color: "transparent"
		border.width: Config.popupBorderWidth * 2
		border.color: Config.foreground
		visible: root.selected
	}
}
