import QtQuick
import qs

Item {
	id: root

	property var action: null
	property string text: root.action ? root.action.text || "" : ""
	property string icon: root.action ? root.action.icon || "" : ""
	property string kind: root.action ? root.action.kind || "secondary" : "secondary"
	property bool busy: root.action ? root.action.busy === true : false
	property bool confirm: root.action ? root.action.confirm === true : false
	property bool armed: false

	readonly property bool danger: root.kind === "danger" || root.armed
	readonly property bool filled: root.kind === "primary" || root.armed
	readonly property bool iconOnly: root.text === ""
	readonly property color fill: root.armed ? Config.red : root.kind === "primary" ? Config.foreground : hit.containsMouse ? Config.toggleHover : root.kind === "secondary" ? Config.surfaceHover : "transparent"
	readonly property color ink: root.filled ? Config.surface : root.danger ? Config.red : Config.foreground

	signal clicked()

	implicitHeight: Config.appChipHeight
	implicitWidth: root.iconOnly ? Config.appChipHeight : label.implicitWidth + (root.icon !== "" || root.busy ? Config.fontSize + content.spacing : 0) + Config.appGap * 2
	enabled: root.action ? root.action.enabled !== false : true
	opacity: root.enabled ? 1 : Config.disabledOpacity
	activeFocusOnTab: root.enabled

	Accessible.role: Accessible.Button
	Accessible.name: root.text !== "" ? root.text : root.icon
	Accessible.onPressAction: root.activate()

	Keys.onSpacePressed: root.activate()
	Keys.onReturnPressed: root.activate()
	Keys.onEnterPressed: root.activate()

	function activate() {
		if (!root.enabled || root.busy)
			return;
		if (root.confirm && !root.armed) {
			root.armed = true;
			disarm.restart();
			return;
		}
		root.armed = false;
		disarm.stop();
		if (root.action && root.action.run)
			root.action.run();
		root.clicked();
	}

	Timer {
		id: disarm

		interval: Config.confirmMs
		onTriggered: root.armed = false
	}

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: root.fill

		Behavior on color {
			ColorAnimation {
				duration: Config.toggleMs
			}
		}
	}

	Row {
		id: content

		anchors.centerIn: parent
		spacing: Config.gapsIn * 2

		Braille {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.busy
			running: root.busy
			ink: root.ink
		}

		Icon {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.icon !== "" && !root.busy
			width: Config.fontSize
			height: Config.fontSize
			size: Config.fontSize
			name: root.icon
			ink: root.ink
		}

		Label {
			id: label

			anchors.verticalCenter: parent.verticalCenter
			anchors.verticalCenterOffset: label.capOffset
			visible: !root.iconOnly
			width: Math.min(label.implicitWidth, Math.max(0, root.width - root.implicitWidth + label.implicitWidth))
			ink: root.ink
			text: root.text
		}
	}

	FocusRing {
		radius: height / 2
	}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		enabled: root.enabled
		cursorShape: Qt.PointingHandCursor
		onClicked: root.activate()
	}
}
