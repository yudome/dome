pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs
import qs.services
import qs.ui
import qs.appkit

AppWindow {
	id: win

	property string mode: "lock"
	readonly property string me: Quickshell.env("USER") || "user"

	appTitle: "Lock screen preview"
	preset: "large"

	readonly property var profile: Yudae.lockscreen.profile || ({})

	Item {
		id: mock

		property string expect: ""
		property var users: [win.me, "guest"]
		property var sessions: [{ name: "Hyprland" }, { name: "Plasma" }, { name: "niri" }]
		property int user: 0
		property int session: 0

		readonly property string userName: mock.users[mock.user] || ""
		readonly property string sessionName: (mock.sessions[mock.session] || {}).name || ""

		signal accepted()
		signal rejected(string text)

		function stepUser(delta) {
			if (mock.users.length > 0)
				mock.user = (mock.user + delta + mock.users.length) % mock.users.length;
		}

		function stepSession(delta) {
			mock.session = (mock.session + delta + mock.sessions.length) % mock.sessions.length;
		}

		function check(user, password) {
			mock.expect = password;
			answer.restart();
		}

		Timer {
			id: answer

			interval: Config.lockFadeMs * 2
			onTriggered: mock.expect === "wrong" ? mock.rejected(Config.lockWrongText) : mock.accepted()
		}
	}

	Store {
		id: previewStore

		auth: mock
		dry: true
		onUnlocked: relock.restart()
	}

	Timer {
		id: relock

		interval: Config.lockFadeMs * 2
		onTriggered: {
			previewStore.reset(true);
			surface.replay();
		}
	}

	AppAction {
		id: wrongAction

		text: "Wrong password"
		onTriggered: {
			previewStore.wake();
			previewStore.password = "wrong";
			previewStore.submit();
		}
	}

	AppAction {
		id: idleAction

		text: "Idle"
		onTriggered: previewStore.awake = false
	}

	AppAction {
		id: replayAction

		text: "Replay"
		icon: "refresh"
		onTriggered: {
			previewStore.reset(true);
			surface.replay();
		}
	}

	AppScaffold {
		anchors.fill: parent

		header: AppHeader {
			title: "Lock screen preview"
			actions: [wrongAction, idleAction, replayAction]

			Tabs {
				model: [{ value: "lock", label: "Lock" }, { value: "greeter", label: "Greeter" }]
				current: win.mode
				onPicked: value => win.mode = value
			}
		}

		Surface {
			id: surface

			anchors.fill: parent
			store: previewStore
			auth: win.mode === "greeter" ? mock : null
			entry: win.mode === "greeter" ? (win.profile.greeter || ({})) : (win.profile.lock || ({}))
			userName: win.mode === "greeter" ? mock.userName : win.me
			home: Quickshell.env("HOME") || ""
		}
	}
}
