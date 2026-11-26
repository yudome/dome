import QtQuick
import Quickshell
import Quickshell.Wayland

Item {
	id: root

	property bool armed: true
	property real seconds: 0

	readonly property string key: root.armed && root.seconds > 0 ? String(Math.max(1, Math.round(root.seconds))) : ""

	signal idle()

	function rearm() {
		monitor.active = false;
		monitor.active = root.key !== "";
	}

	onKeyChanged: root.rearm()
	Component.onCompleted: root.rearm()

	LazyLoader {
		id: monitor

		IdleMonitor {
			timeout: Math.max(1, Math.round(root.seconds))
			onIsIdleChanged: if (isIdle)
				root.idle()
		}
	}
}
