pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.services
import "features/lock"

ShellRoot {
	id: lockRoot

	readonly property bool preview: Quickshell.env("QS_LOCK_PREVIEW") === "1"
	readonly property string pidFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/qs-lock.pid"

	property int focusIndex: 0
	property bool reveal: false

	Session {
		id: auth

		preview: lockRoot.preview

		onModeChanged: if (auth.mode !== "locked")
			lockRoot.reveal = false

		onUnlocked: {
			lock.locked = false;
			Quickshell.execDetached(["rm", "-f", lockRoot.pidFile]);
			Qt.quit();
		}
	}

	WlSessionLock {
		id: lock

		locked: true

		Stage {
			source: auth
			focusIndex: lockRoot.focusIndex
			reveal: lockRoot.reveal

			onFocusPicked: function (index) {
				lockRoot.focusIndex = index;
			}

			onRevealPicked: function (shown) {
				lockRoot.reveal = shown;
			}
		}
	}

	IdleMonitor {
		enabled: !lockRoot.preview && Config.lockSleepAfterMinutes > 0 && !Yudae.awakeWanted
		timeout: Math.max(1, Config.lockSleepAfterMinutes * 60)

		onIsIdleChanged: if (isIdle)
			Quickshell.execDetached(["systemctl", "suspend"])
	}

	IpcHandler {
		target: "lock"

		function power() {
			lockRoot.focusIndex = 2;
		}
	}
}
