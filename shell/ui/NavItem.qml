import QtQuick
import qs

Item {
	id: root

	property string text: ""
	property string icon: ""
	property string glyph: ""
	property bool selected: false
	property bool showLabel: true

	readonly property real badge: root.height - Config.gapsIn * 2.5

	signal clicked()

	implicitHeight: Config.appChipHeight + Config.gapsIn
	implicitWidth: Config.appSidebarWidth
	activeFocusOnTab: true

	Accessible.role: Accessible.PageTab
	Accessible.name: root.text
	Accessible.selected: root.selected
	Accessible.onPressAction: root.clicked()

	Keys.onSpacePressed: root.clicked()
	Keys.onReturnPressed: root.clicked()

	Rectangle {
		anchors.fill: parent
		radius: Config.appControlRadius
		color: root.selected ? Config.toggleHover : Config.surfaceHover
		opacity: root.selected || hit.containsMouse ? 1 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: Config.toggleMs
			}
		}
	}

	Rectangle {
		id: mark

		x: Config.gapsIn * 1.5
		anchors.verticalCenter: parent.verticalCenter
		width: root.badge
		height: root.badge
		radius: Config.appControlRadius - Config.gapsIn / 4
		color: root.selected ? Config.foreground : Config.toggleTrack

		Icon {
			anchors.centerIn: parent
			width: Config.fontSize
			height: Config.fontSize
			size: Config.fontSize - 1
			name: root.icon
			glyph: root.glyph
			ink: root.selected ? Config.surface : Config.foreground
		}
	}

	Label {
		id: label

		anchors.left: mark.right
		anchors.leftMargin: Config.appControlRadius + Config.gapsIn / 2
		anchors.right: parent.right
		anchors.rightMargin: Config.appControlRadius
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: label.capOffset
		visible: root.showLabel
		ink: root.selected ? Config.foreground : Config.muted
		text: root.text
	}

	FocusRing {}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}
}
