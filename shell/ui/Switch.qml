import QtQuick
import qs

Item {
	id: root

	property bool checked: false
	property string label: ""

	readonly property real knob: root.height - Config.togglePadding * 2

	signal toggled(bool checked)

	implicitHeight: Config.toggleHeight
	implicitWidth: Config.toggleHeight * 2 - Config.togglePadding * 2
	activeFocusOnTab: root.enabled
	opacity: root.enabled ? 1 : Config.disabledOpacity

	Accessible.role: Accessible.CheckBox
	Accessible.checkable: true
	Accessible.checked: root.checked
	Accessible.name: root.label
	Accessible.onToggleAction: root.flip()
	Accessible.onPressAction: root.flip()

	Keys.onSpacePressed: root.flip()
	Keys.onReturnPressed: root.flip()

	function flip() {
		if (root.enabled)
			root.toggled(!root.checked);
	}

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: root.checked ? Config.foreground : hit.containsMouse ? Config.toggleHover : Config.toggleTrack

		Behavior on color {
			ColorAnimation {
				duration: Config.toggleMs
			}
		}
	}

	Rectangle {
		x: root.checked ? root.width - root.knob - Config.togglePadding : Config.togglePadding
		y: Config.togglePadding
		width: root.knob
		height: root.knob
		radius: root.knob / 2
		color: root.checked ? Config.surface : Config.foreground

		Behavior on x {
			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}
	}

	FocusRing {
		radius: height / 2
	}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.flip()
	}
}
