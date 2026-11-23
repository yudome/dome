pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs
import qs.ui
import qs.appkit
import qs.services
import "../../bar"

Item {
	id: root

	required property var layout
	required property var store
	property string part: "left"
	property bool ready: false

	readonly property var monitor: root.store.monitor || ({ width: 1920, height: 1080, scale: 1 })
	readonly property real screenWidth: Math.round(root.monitor.width / (root.monitor.scale || 1))
	readonly property real screenHeight: Math.round(root.monitor.height / (root.monitor.scale || 1))
	readonly property var bar: root.layout && root.layout.bar ? root.layout.bar : ({})
	readonly property var slots: root.bar.layout || ({})
	readonly property bool atBottom: root.bar.position === "bottom"
	readonly property real outer: Config.barFloating ? Config.gapsOut : 0
	readonly property real shot: Math.max(root.screenWidth, root.width)
	readonly property real shift: root.part === "left" ? 0 : root.part === "right" ? root.width - root.shot : Math.round((root.width - root.shot) / 2)
	readonly property int at: root.part === "left" ? 0 : root.part === "right" ? 2 : 1

	height: loader.height + root.outer + Config.settingsPreviewBelow + Metrics.gap

	function shiftPart(step) {
		root.part = ["left", "center", "right"][Calc.clamp(root.at + step, 0, 2)];
	}

	Item {
		id: surface

		anchors.fill: parent
		layer.enabled: true
		layer.effect: MultiEffect {
			maskEnabled: true
			maskSource: mask
		}

		Rectangle {
			anchors.fill: parent
			color: Config.surface
		}

		Image {
		x: root.shift
		y: root.atBottom ? -(root.screenHeight - root.height) : 0
		width: root.shot
		height: root.screenHeight
		fillMode: Image.PreserveAspectCrop
		asynchronous: true
		mipmap: true
		source: root.store.wallpaper !== "" ? "file://" + root.store.wallpaper : ""
		}

	Loader {
		id: loader

		active: root.ready
		x: root.shift + root.outer
		y: root.atBottom ? root.height - height - root.outer : root.outer
		width: root.shot - root.outer * 2
		height: item ? item.implicitHeight : 0
		sourceComponent: bodyComponent
	}

	Component {
		id: bodyComponent

		BarBody {
			width: parent ? parent.width : root.shot
			layout: ({
				position: root.bar.position || "top",
				centerAnchor: root.bar.centerAnchor || "",
				left: root.slots.left || [],
				center: root.slots.center || [],
				right: root.slots.right || []
			})
			clear: root.bar.transparent === true
			sample: true
		}
	}

	Component.onCompleted: Qt.callLater(function () { root.ready = true; })

		MouseArea {
			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.AllButtons
		}
	}

	Rectangle {
		id: mask

		anchors.fill: parent
		radius: Metrics.radius
		layer.enabled: true
		visible: false
	}

	IconButton {
		visible: root.at > 0
		anchors.left: parent.left
		anchors.leftMargin: Metrics.gap
		anchors.verticalCenter: parent.verticalCenter
		selected: true
		name: "chevron"
		label: "Left"
		onClicked: root.shiftPart(-1)
	}

	IconButton {
		visible: root.at < 2
		anchors.right: parent.right
		anchors.rightMargin: Metrics.gap
		anchors.verticalCenter: parent.verticalCenter
		selected: true
		name: "right"
		label: "Right"
		onClicked: root.shiftPart(1)
	}
}
