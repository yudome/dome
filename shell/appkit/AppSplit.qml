import QtQuick
import qs
import qs.ui

Item {
	id: root

	property real size: Config.appSidebarWidth
	property real minSize: Config.appSidebarMin
	property real maxSize: Math.min(Config.appSidebarMax, root.width / 2)
	property bool collapsed: false
	property bool resizable: true
	property bool ruled: true
	property real dragged: -1

	readonly property real paneWidth: root.collapsed ? 0 : Math.round(Math.max(root.minSize, Math.min(root.maxSize, root.dragged >= 0 ? root.dragged : root.size)))

	property alias first: firstPane.data
	property alias second: secondPane.data

	Item {
		id: firstPane

		width: root.paneWidth
		height: root.height
		visible: !root.collapsed
		clip: true
	}

	Rectangle {
		x: root.paneWidth - width
		width: Config.popupBorderWidth
		height: root.height
		color: Config.rule
		visible: root.ruled && !root.collapsed
	}

	Item {
		id: secondPane

		x: root.paneWidth
		width: root.width - root.paneWidth
		height: root.height
	}

	MouseArea {
		x: root.paneWidth - width / 2
		width: Config.gapsIn * 2
		height: root.height
		visible: root.resizable && !root.collapsed
		cursorShape: Qt.SizeHorCursor
		preventStealing: true

		onPressed: root.dragged = root.paneWidth
		onPositionChanged: function (mouse) {
			if (pressed)
				root.dragged = Math.max(root.minSize, Math.min(root.maxSize, root.dragged + mouse.x - width / 2));
		}
		onReleased: {
			root.size = root.paneWidth;
			root.dragged = -1;
		}
	}
}
