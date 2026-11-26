pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs

Scope {
	id: root

	property string machine: ""
	property var repoBody: ({})
	property var spareBody: ({})

	readonly property var body: Object.keys(root.repoBody).length > 0 ? root.repoBody : root.spareBody
	readonly property var greeter: root.body.greeter || ({})

	function parse(text) {
		try {
			return JSON.parse(text);
		} catch (error) {
			return ({});
		}
	}

	FileView {
		path: "/etc/machine-id"
		printErrors: false
		onLoaded: root.machine = text().trim() || "local"
		onLoadFailed: root.machine = "local"
	}

	FileView {
		id: repoFile

		path: root.machine === "" ? "" : Quickshell.shellDir + "/cache/lockscreen/" + root.machine + "/profile.json"
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: root.repoBody = root.parse(text())
	}

	FileView {
		id: spareFile

		path: root.machine === "" ? "" : "/var/tmp/yudae-lockscreen/" + root.machine + "/profile.json"
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: root.spareBody = root.parse(text())
	}

	Timer {
		interval: 2000
		repeat: true
		running: root.machine !== "" && Object.keys(root.body).length === 0
		onTriggered: {
			repoFile.reload();
			spareFile.reload();
		}
	}

	GreetdAuth {
		id: greetd

		defaultUser: Quickshell.env("QS_GREETER_USER") || ""
		profile: root.body
	}

	Store {
		id: greeterStore

		auth: greetd
		greeter: true
		user: greetd.userName
		onUnlocked: greetd.launch()
	}

	Variants {
		model: Quickshell.screens

		PanelWindow {
			id: panel

			required property var modelData

			screen: panel.modelData
			anchors.top: true
			anchors.bottom: true
			anchors.left: true
			anchors.right: true
			exclusionMode: ExclusionMode.Ignore
			color: Config.surface
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.namespace: "yudae-greeter"
			WlrLayershell.keyboardFocus: panel.modelData === Quickshell.screens[0] ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

			Surface {
				anchors.fill: parent
				store: greeterStore
				auth: greetd
				entry: root.greeter
				userName: greetd.userName
				home: greetd.homes[greetd.userName] || ""
			}
		}
	}
}
