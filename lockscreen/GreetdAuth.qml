import QtQuick
import Quickshell
import Quickshell.Services.Greetd
import qs

Item {
	id: root

	property string defaultUser: ""
	property string pending: ""
	property bool busy: false
	property var profile: ({})

	readonly property var people: (root.profile.users || []).filter(person => person.name !== root.defaultUser)
	readonly property var users: (root.defaultUser !== "" ? [root.defaultUser] : []).concat(root.people.map(person => person.name))
	readonly property var homes: (root.profile.users || []).reduce((found, person) => Object.assign(found, { [person.name]: person.home }), {})
	readonly property var sessions: [{ name: "Hyprland", exec: ["/usr/bin/start-hyprland"] }].concat((root.profile.sessions || []).filter(entry => entry.exec.length > 0 && entry.exec.join(" ") !== "/usr/bin/start-hyprland"))
	property int user: 0
	property int session: 0

	readonly property string userName: root.users[root.user] || root.defaultUser
	readonly property string sessionName: (root.sessions[root.session] || {}).name || ""
	readonly property string wrapper: Quickshell.shellDir + "/lockscreen/session"

	signal accepted()
	signal rejected(string text)

	function stepUser(delta) {
		if (root.users.length > 0)
			root.user = (root.user + delta + root.users.length) % root.users.length;
	}

	function stepSession(delta) {
		if (root.sessions.length > 0)
			root.session = (root.session + delta + root.sessions.length) % root.sessions.length;
	}

	function check(user, password) {
		root.busy = true;
		root.pending = password;
		guard.restart();
		Greetd.createSession(root.userName);
	}

	function launch() {
		const home = root.homes[root.userName] || ("/home/" + root.userName);
		const exec = (root.sessions[root.session] || root.sessions[0]).exec;

		Greetd.launch([root.wrapper, home + "/.local/state/session.log"].concat(exec), ["XDG_SESSION_TYPE=wayland"], true);
	}

	Connections {
		target: Greetd

		function onAuthMessage(message, error, responseRequired, echoResponse) {
			if (!responseRequired)
				return;

			const value = root.pending;

			root.pending = "";
			guard.restart();
			Greetd.respond(value);
		}

		function onAuthFailure(message) {
			guard.stop();
			root.pending = "";
			root.busy = false;
			root.rejected(Config.lockWrongText);
		}

		function onReadyToLaunch() {
			guard.stop();
			root.busy = false;
			root.accepted();
		}

		function onError(error) {
			guard.stop();
			root.pending = "";
			if (!root.busy)
				return;
			root.busy = false;
			root.rejected(error);
		}
	}

	Timer {
		id: guard

		interval: 8000
		onTriggered: {
			Greetd.cancelSession();
			root.pending = "";
			root.busy = false;
			root.rejected(Config.lockPamError);
		}
	}
}
