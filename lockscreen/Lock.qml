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

		leave.stop();
		root.leaving = false;
		root.outro = 0;
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

	property real outro: 0
	property bool leaving: false
	readonly property var entry: root.profile.lock || ({})
	readonly property var still: root.entry.video ? { source: root.entry.rest || root.entry.first || "" } : root.entry

	function dock(screen) {
		const bar = BarInk.bars.find(b => b.visible && b.screen && screen && b.screen.name === screen.name);
		return bar ? Qt.rect(bar.origin.x, bar.origin.y, bar.width, bar.implicitHeight) : Qt.rect(0, 0, 0, 0);
	}

	Connections {
		target: lockStore

		function onModeChanged() {
			if (lockStore.mode !== "open")
				return;
			root.leaving = true;
			leave.restart();
		}
	}

	NumberAnimation {
		id: leave

		target: root
		property: "outro"
		from: 0
		to: 1
		duration: Config.lockFoldMs
		onFinished: root.leaving = false
	}

	LazyLoader {
		active: root.locked

		WlSessionLock {
			locked: root.held

			WlSessionLockSurface {
				id: lockSurface

				color: Config.surface

				Surface {
					anchors.fill: parent
					dock: root.dock(lockSurface.screen)
					outro: root.outro
					store: lockStore
					entry: root.entry
					userName: lockStore.user
					home: Quickshell.env("HOME") || ""
				}
			}
		}
	}

	LazyLoader {
		active: root.leaving

		Variants {
			model: Quickshell.screens

			PanelWindow {
				id: fade

				required property var modelData

				screen: fade.modelData
				anchors.top: true
				anchors.bottom: true
				anchors.left: true
				anchors.right: true
				exclusionMode: ExclusionMode.Ignore
				color: "transparent"
				mask: Region {}
				WlrLayershell.layer: WlrLayer.Overlay
				WlrLayershell.namespace: "yudae-unlock"
				WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

				Surface {
					anchors.fill: parent
					dock: root.dock(fade.modelData)
					outro: root.outro
					store: lockStore
					entry: root.still
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
