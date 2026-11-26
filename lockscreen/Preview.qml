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
	readonly property string shots: Quickshell.env("QS_LOCK_SHOTS") || ""
	readonly property string me: Quickshell.env("USER") || "user"

	appTitle: "Lock screen preview"
	preset: "large"

	readonly property var profile: Yudae.lockscreen.profile || ({})

	Item {
		id: mock

		property string expect: ""
		property var users: [win.me, "guest"]
		property var sessions: ["Hyprland", "Plasma", "niri"]
		property int user: 0
		property int session: 0

		readonly property string userName: mock.users[mock.user] || ""
		readonly property string sessionName: mock.sessions[mock.session] || ""

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

	Item {
		id: camera

		property var plan: []
		property int step: 0

		function next() {
			if (camera.step >= camera.plan.length) {
				Qt.quit();
				return;
			}
			const shot = camera.plan[camera.step];
			win.mode = shot.mode;
			previewStore.reset(true);
			if (shot.typed)
				previewStore.type(shot.typed);
			if (shot.wrong) {
				previewStore.password = "wrong";
				previewStore.submit();
			}
			if (shot.choosing)
				previewStore.choosing = true;
			if (shot.idle)
				previewStore.awake = false;
			if (shot.replay)
				surface.replay();
			wait.interval = shot.wait;
			wait.restart();
		}

		Timer {
			id: wait

			onTriggered: surface.grabToImage(result => {
				const shot = camera.plan[camera.step];
				result.saveToFile(win.shots + "/" + shot.name + ".png");
				camera.step++;
				camera.next();
			})
		}

		Component.onCompleted: {
			if (win.shots === "")
				return;
			const plan = [];
			plan.push({ name: "lock", mode: "lock", replay: true, wait: 5000 });
			plan.push({ name: "greeter", mode: "greeter", typed: "secret", wait: 1200 });
			plan.push({ name: "wrong", mode: "lock", wrong: true, wait: Config.lockFadeMs * 3 });
			plan.push({ name: "greeter-menu", mode: "greeter", choosing: true, wait: 1200 });
			plan.push({ name: "idle", mode: "lock", idle: true, wait: Config.lockFadeMs * 3 });
			camera.plan = plan;
			camera.next();
		}
	}
}
