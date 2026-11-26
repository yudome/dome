import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.services

Scope {
	id: root

	property bool locked: false
	property bool held: false
	readonly property var profile: Yudae.lockscreen.profile || ({})

	function lock(idle) {
		if (root.locked)
			return;

		lockStore.reset(!idle);
		root.locked = true;
		root.held = true;
		Yudae.cmd("lockscreen", { lock: true });
	}

	function unlock() {
		root.held = false;
		Qt.callLater(() => root.locked = false);
		Yudae.cmd("lockscreen", { unlock: true });
	}

	PamAuth {
		id: pam
	}

	Store {
		id: lockStore

		auth: pam
		user: Quickshell.env("USER") || ""
		onUnlocked: root.unlock()
	}

	LazyLoader {
		active: root.locked

		WlSessionLock {
			locked: root.held

			WlSessionLockSurface {
				color: Config.surface

				Surface {
					anchors.fill: parent
					store: lockStore
					entry: root.profile.lock || ({})
					userName: lockStore.user
					home: Quickshell.env("HOME") || ""
				}
			}
		}
	}

	Connections {
		target: Yudae

		function onLockedChanged() {
			if (Yudae.locked)
				root.lock(false);
		}

	}

	Component.onCompleted: if (Yudae.locked)
		root.lock(false)

	FileView {
		id: started

		path: Quickshell.env("YUDAE_LOCK_AT_START") === "1" ? (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/yudae-started-" + (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "session") : ""
		printErrors: false
		onLoadFailed: {
			started.setText("started\n");
			root.lock(false);
		}
	}

	Idle {
		armed: root.locked && !Yudae.awakeWanted
		seconds: Config.lockSleepAfterMinutes * 60
		onIdle: lockStore.power("suspend")
	}
}
