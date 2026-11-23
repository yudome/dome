import QtQuick
import qs
import qs.ui

Item {
	id: root

	property bool checked: false

	signal toggled()

	implicitWidth: Config.appCaptionSize + Config.gapsIn
	implicitHeight: implicitWidth
	activeFocusOnTab: true

	Accessible.role: Accessible.CheckBox
	Accessible.checkable: true
	Accessible.checked: root.checked
	Accessible.onToggleAction: root.toggled()

	Keys.onSpacePressed: root.toggled()

	Rectangle {
		anchors.fill: parent
		radius: width / 2
		color: root.checked ? Config.foreground : Config.toggleHover

		Behavior on color {
			ColorAnimation { duration: Config.toggleMs }
		}
	}

	Rectangle {
		anchors.centerIn: parent
		width: root.checked ? root.width * 0.4 : 0
		height: width
		radius: width / 2
		color: Config.surface

		Behavior on width {
			NumberAnimation { duration: Config.toggleMs; easing.type: Easing.OutCubic }
		}
	}

	FocusRing {
		radius: height / 2
	}

	MouseArea {
		anchors.fill: parent
		anchors.margins: -Config.gapsIn
		onClicked: root.toggled()
	}
}
