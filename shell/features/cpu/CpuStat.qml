import QtQuick
import qs.ui
import qs
import qs.services

BarStat {
	id: root

	inkId: "cpu"

	readonly property var source: Yudae.system.cpu || ({})
	readonly property var cores: root.source.cores || []
	readonly property real pct: root.source.pct || 0

	icon: Config.iconCpu

	popupContent: Component {
		CpuMonitor {
			id: monitor

			source: root
			onCloseRequested: root.closePopup()
		}
	}
}
