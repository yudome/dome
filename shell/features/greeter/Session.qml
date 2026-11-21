import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import qs
import qs.services

Item {
	id: root

	property string password: ""
	property int filled: 0
	property string mode: "locked"
	property string message: ""
	property bool preview: false
	property bool cooling: false
	property string pending: ""
	property string defaultUser: ""

	readonly property bool switchable: true
	property var users: []
	property var homes: ({})
	property var sessions: [{ name: "Hyprland", exec: ["/usr/bin/start-hyprland"] }]
	property int user: 0
	property int session: 0

	readonly property string userName: root.users[root.user] || root.defaultUser
	readonly property string wrapper: Quickshell.shellDir + "/features/greeter/session"

	function choiceName(row) {
		return row === 0 ? (root.sessions[root.session] || {}).name || "" : root.userName;
	}

	function step(row, delta) {
		const count = row === 0 ? root.sessions.length : root.users.length;

		if (count === 0)
			return;

		if (row === 0)
			root.session = (root.session + delta + count) % count;
		else
			root.user = (root.user + delta + count) % count;
	}

	function type(text) {
		if (text === "" || root.mode === "checking" || root.mode === "open" || root.password.length >= 256)
			return;

		root.password += text;
		root.filled = root.password.length;
		root.message = "";
		root.mode = "locked";
	}

	function back() {
		if (root.mode === "checking" || root.mode === "open" || root.password.length === 0)
			return;

		root.password = root.password.slice(0, -1);
		root.filled = root.password.length;
	}

	function clear() {
		if (root.mode === "checking" || root.mode === "open")
			return;

		root.password = "";
		root.filled = 0;
		root.message = "";
		root.mode = "locked";
	}

	function dismiss() {
		if (root.preview)
			Qt.quit();
		else
			root.clear();
	}

	function submit() {
		if (root.password === "" || root.mode === "checking" || root.mode === "open" || root.cooling)
			return;

		root.mode = "checking";
		root.pending = root.password;
		root.password = "";

		if (root.preview) {
			root.open();
			return;
		}

		guard.restart();
		Greetd.createSession(root.userName);
	}

	function open() {
		if (root.mode === "open")
			return;

		root.mode = "open";
		root.pending = "";

		if (root.preview) {
			Qt.quit();
			return;
		}

		const home = root.homes[root.userName] || ("/home/" + root.userName);
		const exec = (root.sessions[root.session] || root.sessions[0]).exec;

		Greetd.launch([root.wrapper, home + "/.local/state/session.log"].concat(exec), ["XDG_SESSION_TYPE=wayland"], true);
	}

	function fail(text) {
		root.password = "";
		root.pending = "";
		root.filled = 0;
		root.mode = "wrong";
		root.message = text === "" ? Config.lockWrongText : text;
		root.cooling = true;
		relax.restart();
	}

	FileView {
		path: "/etc/passwd"
		printErrors: false

		onLoaded: {
			const users = [];
			const homes = {};

			for (const line of text().split("\n")) {
				const fields = line.split(":");

				if (fields.length < 7)
					continue;

				const uid = parseInt(fields[2]);

				homes[fields[0]] = fields[5];

				if (uid >= 1000 && uid < 65534 && !fields[6].includes("nologin") && !fields[6].endsWith("false"))
					users.push(fields[0]);
			}

			const others = users.filter(name => name !== root.defaultUser);

			root.homes = homes;
			root.users = root.defaultUser !== "" ? [root.defaultUser].concat(others) : others;
		}
	}

	Process {
		running: true
		command: ["sh", "-c", "grep -H -e '^Name=' -e '^Exec=' /usr/share/wayland-sessions/*.desktop /usr/share/xsessions/*.desktop 2>/dev/null"]

		stdout: StdioCollector {
			onStreamFinished: {
				const found = {};
				const order = [];

				for (const line of text.split("\n")) {
					const at = line.indexOf(":");

					if (at < 0)
						continue;

					const file = line.slice(0, at);
					const entry = line.slice(at + 1);
					const key = entry.startsWith("Name=") ? "name" : "exec";

					if (!found[file]) {
						found[file] = {};
						order.push(file);
					}

					if (found[file][key] === undefined)
						found[file][key] = entry.slice(5);
				}

				const sessions = [root.sessions[0]];

				for (const file of order) {
					const exec = (found[file].exec || "").split(/\s+/).filter(part => part !== "" && !part.startsWith("%"));

					if (exec.length === 0 || sessions.some(known => known.exec.join(" ") === exec.join(" ")))
						continue;

					sessions.push({ name: found[file].name || file.replace(/^.*\//, "").replace(/\.desktop$/, ""), exec: exec });
				}

				root.sessions = sessions;
			}
		}
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
			root.fail(Config.lockWrongText);
		}

		function onReadyToLaunch() {
			guard.stop();
			root.open();
		}

		function onError(error) {
			guard.stop();

			if (root.mode === "checking")
				root.fail(error);
		}
	}

	Timer {
		id: guard

		interval: 8000
		onTriggered: {
			Greetd.cancelSession();
			root.fail(Config.lockPamError);
		}
	}

	Timer {
		id: relax

		interval: Math.max(0, Config.lockCooldownMs)
		onTriggered: {
			root.cooling = false;

			if (root.mode === "wrong")
				root.mode = "locked";
		}
	}
}
