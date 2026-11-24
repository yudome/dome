import QtQuick
import qs.ui
import qs
import qs.services

BarStat {
	id: root

	inkId: "cpu"

	readonly property var source: Yudae.system.cpu || ({})
	readonly property var cores: root.source.cores || []
	property var history: []

	pct: root.source.pct || 0
	barColor: root.source.color || Config.cpuBase
	icon: Config.iconCpu
	value: Math.round(root.pct) + "%"

	function record() {
		if (root.source.pct === undefined)
			return;

		const keep = Config.cpuGraphSamples - 1;
		const past = root.history.length > keep ? root.history.slice(root.history.length - keep) : root.history;

		root.history = past.concat([root.source.pct]);
	}

	onSourceChanged: root.record()

	popupContent: Component {
		CpuMonitor {
			id: monitor

			source: root
			onCloseRequested: root.closePopup()
		}
	}
}
