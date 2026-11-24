import QtQuick
import qs.ui
import qs
import qs.services

BarStat {
	id: root

	inkId: "memory"

	readonly property var memory: Yudae.system.memory || null
	readonly property real pct: root.memory ? root.memory.pct : 0

	icon: Config.iconMemory

	popupContent: Component {
		MemoryMonitor {
			id: monitor

			source: root
			onCloseRequested: root.closePopup()
		}
	}
}
