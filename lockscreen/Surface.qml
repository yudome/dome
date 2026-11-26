import QtQuick
import qs
import qs.ui

Item {
	id: root

	required property var store
	property var auth: null
	property var entry: ({})
	property string userName: ""
	property string home: ""
	property rect dock: Qt.rect(0, 0, 0, 0)
	property real outro: 0

	readonly property bool greeter: root.auth !== null
	readonly property bool shown: root.store.awake && root.store.mode !== "open"

	property point anchor: Qt.point(-1, -1)

	function replay() {
		backdrop.replay();
	}

	function nudge(x, y) {
		if (root.anchor.x < 0) {
			root.anchor = Qt.point(x, y);
			return;
		}
		if (Math.abs(x - root.anchor.x) + Math.abs(y - root.anchor.y) > Config.appGap) {
			root.anchor = Qt.point(x, y);
			root.store.wake();
		}
	}

	function phase(from, to) {
		const t = Math.min(1, Math.max(0, (root.outro - from) / (to - from)));
		return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(2 - 2 * t, 3) / 2;
	}

	Item {
		anchors.fill: parent
		opacity: 1 - root.phase(0.25, 1)

		Backdrop {
			id: backdrop

			anchors.fill: parent
			entry: root.entry
		}

		Rectangle {
			anchors.fill: parent
			color: Config.surface
			opacity: root.store.awake ? Config.wallpaperScrim : 0

			Fade on opacity {
				duration: Config.lockFadeMs
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		hoverEnabled: true
		onPositionChanged: mouse => root.nudge(mouse.x, mouse.y)
		onPressed: {
			root.store.wake();
			keys.forceActiveFocus();
		}
	}

	Item {
		id: controls

		anchors.fill: parent
		opacity: root.store.awake ? 1 : 0
		enabled: root.shown

		Fade on opacity {
			duration: Config.lockFadeMs
		}

		Panel {
			anchors.fill: parent
			view: root
		}
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true

		Component.onCompleted: keys.forceActiveFocus()

		Keys.onPressed: event => {
			root.store.wake();
			event.accepted = true;

			if (event.key === Qt.Key_Escape && root.store.choosing)
				root.store.choosing = false;
			else if (event.key === Qt.Key_Escape)
				root.store.clear();
			else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
				root.store.submit();
			else if (event.key === Qt.Key_Backspace)
				root.store.back();
			else if (root.greeter && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab))
				root.auth.stepSession(event.key === Qt.Key_Tab ? 1 : -1);
			else if (root.greeter && (event.key === Qt.Key_Up || event.key === Qt.Key_Down))
				root.auth.stepUser(event.key === Qt.Key_Down ? 1 : -1);
			else if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
				event.accepted = false;
			else if (event.text.length > 0 && event.text.charCodeAt(0) >= 0x20)
				root.store.type(event.text);
			else
				event.accepted = false;
		}
	}
}
