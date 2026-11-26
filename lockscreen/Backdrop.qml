import QtQuick
import Yudae.Native
import qs

Item {
	id: root

	property var entry: ({})

	readonly property bool video: !!root.entry.video && !!root.entry.source
	readonly property bool settled: !root.video || player.settled || player.failed
	readonly property string poster: root.video ? (player.failed ? root.entry.rest : root.entry.first) || "" : root.entry.source || ""

	function replay() {
		if (root.video)
			player.restart();
	}

	Rectangle {
		anchors.fill: parent
		color: Config.surface
	}

	Image {
		anchors.fill: parent
		visible: !player.ready
		source: root.poster === "" ? "" : "file://" + root.poster
		sourceSize.width: root.width
		sourceSize.height: root.height
		fillMode: Image.PreserveAspectCrop
		asynchronous: false
		cache: false
	}

	WallVideo {
		id: player

		anchors.fill: parent
		visible: root.video
		source: root.video ? root.entry.source : ""
		still: root.entry.still || 0
		settleMs: root.entry.settleMs || 1200
		curve: root.entry.curve || 3
	}
}
