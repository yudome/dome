import QtQuick
import Quickshell
import qs
import qs.services

Item {
	id: store

	property var auth: null
	property bool greeter: false
	property string user: ""

	property string password: ""
	property string mode: "idle"
	property string message: ""
	property bool cooling: false
	property bool reveal: false
	property bool awake: true
	property bool choosing: false

	readonly property bool busy: store.mode === "checking" || store.mode === "open"
	readonly property var actions: [
		{ name: "Reboot", glyph: Config.iconReboot, power: "reboot" },
		{ name: "Shut down", glyph: Config.iconPowerOff, power: "poweroff" }
	]

	signal unlocked()
	signal shook()

	function power(verb) {
		if (Yudae.connected)
			Yudae.cmd("lockscreen", { power: verb });
		else
			Quickshell.execDetached(["systemctl", verb]);
	}

	function wake() {
		store.awake = true;
		rest.restart();
	}

	function sleep() {
		if (store.password === "" && !store.busy)
			store.awake = false;
	}

	function reset(awake) {
		store.password = "";
		store.mode = "idle";
		store.message = "";
		store.reveal = false;
		store.choosing = false;
		store.cooling = false;
		store.awake = awake;
		if (awake)
			rest.restart();
	}

	function type(text) {
		if (text === "" || store.busy || store.password.length >= 256)
			return;

		store.password += text;
		store.message = "";
		if (store.mode === "wrong")
			store.mode = "idle";
	}

	function back() {
		if (!store.busy)
			store.password = store.password.slice(0, -1);
	}

	function clear() {
		if (store.busy)
			return;

		store.password = "";
		store.message = "";
		store.mode = "idle";
	}

	function submit() {
		if (store.password === "" || store.busy || store.cooling || !store.auth)
			return;

		const value = store.password;

		store.password = "";
		store.mode = "checking";
		store.auth.check(store.user, value);
	}

	Connections {
		target: store.auth

		function onAccepted() {
			store.mode = "open";
			store.message = "";
			grant.restart();
		}

		function onRejected(text) {
			store.mode = "wrong";
			store.message = text === "" ? Config.lockWrongText : text;
			store.cooling = true;
			relax.restart();
			store.shook();
		}
	}

	Timer {
		id: grant

		interval: Config.lockFadeMs
		onTriggered: store.unlocked()
	}

	Timer {
		id: relax

		interval: Math.max(0, Config.lockCooldownMs)
		onTriggered: store.cooling = false
	}

	Timer {
		id: rest

		interval: Math.max(1, Config.lockIdleSeconds) * 1000
		running: Config.lockIdleSeconds > 0 && store.awake
		onTriggered: store.sleep()
	}
}
