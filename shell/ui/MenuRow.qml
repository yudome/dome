import QtQuick
import qs

Item {
	id: root

	property string text: ""
	property string icon: ""
	property string source: ""
	property bool submenu: false
	property bool flush: false
	property real indent: 0
	property bool danger: false
	property bool selected: false
	property bool current: false
	property bool armed: false

	readonly property bool hovered: hit.containsMouse
	readonly property color ink: root.armed ? Config.surface : root.danger ? Config.red : Config.foreground

	signal clicked()

	implicitWidth: label.implicitWidth + Config.appGap * 2 + root.indent + (lead.visible ? Config.fontSize + Config.gapsIn * 2 : 0) + (check.width > 0 ? check.width + Config.gapsIn : 0)
	implicitHeight: Config.appChipHeight
	opacity: root.enabled ? 1 : Config.disabledOpacity
	activeFocusOnTab: root.enabled

	Accessible.role: Accessible.MenuItem
	Accessible.name: root.text
	Accessible.onPressAction: root.clicked()

	Keys.onSpacePressed: root.clicked()
	Keys.onReturnPressed: root.clicked()

	Rectangle {
		anchors.fill: parent
		radius: root.flush ? 0 : Config.appControlRadius
		color: root.armed ? Config.red : Config.surfaceHover
		opacity: root.armed || (hit.containsMouse || root.selected) && root.enabled ? 1 : 0
	}

	Icon {
		id: lead

		anchors.left: parent.left
		anchors.leftMargin: Config.appControlRadius + root.indent
		anchors.verticalCenter: parent.verticalCenter
		visible: root.icon !== "" || root.source !== ""
		width: visible ? Config.fontSize : 0
		height: Config.fontSize
		size: Config.fontSize
		name: root.icon
		source: root.source
		ink: root.ink
	}

	Label {
		id: label

		anchors.left: lead.visible ? lead.right : parent.left
		anchors.leftMargin: lead.visible ? Config.gapsIn * 2 : Config.appControlRadius + Config.gapsIn + root.indent
		anchors.right: check.left
		anchors.rightMargin: Config.gapsIn
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: label.capOffset
		ink: root.ink
		text: root.text
	}

	Icon {
		id: check

		anchors.right: parent.right
		anchors.rightMargin: Config.appControlRadius
		anchors.verticalCenter: parent.verticalCenter
		width: root.current || root.submenu ? Config.fontSize : 0
		height: Config.fontSize
		size: Config.fontSize
		name: root.current ? "check" : root.submenu ? "right" : ""
		ink: root.ink
	}

	FocusRing {}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		enabled: root.enabled
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}
}
