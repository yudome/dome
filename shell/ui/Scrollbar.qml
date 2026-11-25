import QtQuick
import qs
import qs.services

Item {
	id: root

	property Flickable view: null
	property Item edge: root.parent
	property int thickness: Config.scrollbarWidth
	property bool byRow: false
	property real rowStep: 0

	property bool active: false
	property real pending: 0

	readonly property bool needed: root.view !== null && root.view.contentHeight > root.view.height + 1
	readonly property real track: root.view ? root.view.height : 0
	readonly property real range: root.view ? Math.max(1, root.view.contentHeight - root.view.height) : 1
	readonly property real thumb: root.view ? Math.min(root.track, Math.max(Config.scrollbarMinThumb, root.track * root.track / Math.max(1, root.view.contentHeight))) : 0
	readonly property real position: root.view ? Calc.clamp((root.view.contentY - root.view.originY) / root.range, 0, 1) : 0
	readonly property bool hot: hit.containsMouse || hit.pressed
	readonly property real viewTop: root.overlay && root.view ? root.mapFromItem(root.view, 0, 0).y : 0
	readonly property bool overlay: root.byRow

	width: root.overlay ? root.edge.width : Config.scrollbarHoverWidth
	height: root.overlay ? root.edge.height : root.track
	x: {
		if (root.overlay)
			return 0;

		root.parent.width;
		root.parent.x;
		root.edge.width;
		return root.parent.mapFromItem(root.edge, root.edge.width - root.width, 0).x;
	}
	y: {
		if (root.overlay || !root.view)
			return 0;

		root.view.y;
		root.parent.y;
		return root.parent.mapFromItem(root.view, 0, 0).y;
	}
	z: 10
	visible: root.needed
	opacity: root.hot || root.active ? 1 : 0

	Behavior on opacity {
		NumberAnimation {
			duration: Config.scrollbarFadeMs
		}
	}

	WheelHandler {
		enabled: root.byRow && root.view !== null && root.rowStep > 0
		acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

		onWheel: function (event) {
			root.pending += event.angleDelta.y;
			event.accepted = true;

			const notches = Math.trunc(root.pending / 120);

			if (notches === 0)
				return;

			root.pending -= notches * 120;
			const range = Math.max(0, root.view.contentHeight - root.view.height);
			const at = Math.round(root.view.contentY / root.rowStep) - notches;

			root.view.contentY = Calc.clamp(at * root.rowStep, 0, range);
		}
	}

	Connections {
		target: root.view

		function onContentYChanged() {
			root.active = true;
			idle.restart();
		}
	}

	Timer {
		id: idle

		interval: Config.scrollbarIdleMs
		onTriggered: root.active = false
	}

	Rectangle {
		id: bar

		anchors.right: parent.right
		y: root.viewTop + root.position * (root.track - root.thumb)
		width: root.hot ? Config.scrollbarHoverWidth : root.thickness
		height: root.thumb
		radius: width / 2
		color: Config.dim

		Behavior on width {
			NumberAnimation {
				duration: Config.scrollbarFadeMs
			}
		}
	}

	MouseArea {
		id: hit

		property real grab: 0

		anchors.right: parent.right
		width: Config.scrollbarHoverWidth
		height: root.track
		y: root.viewTop
		hoverEnabled: true
		enabled: root.thickness > 0
		preventStealing: true

		function scrollTo(y) {
			const free = Math.max(1, root.track - root.thumb);
			root.view.contentY = root.view.originY + Calc.clamp((y - hit.grab) / free, 0, 1) * root.range;
		}

		onPressed: function (mouse) {
			const onThumb = mouse.y >= bar.y && mouse.y <= bar.y + bar.height;
			hit.grab = onThumb ? mouse.y - bar.y : root.thumb / 2;
			if (!onThumb)
				hit.scrollTo(mouse.y);
		}
		onPositionChanged: function (mouse) {
			if (pressed)
				hit.scrollTo(mouse.y);
		}
	}
}
