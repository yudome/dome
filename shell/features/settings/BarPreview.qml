import QtQuick
import Qt5Compat.GraphicalEffects
import qs
import qs.ui
import qs.services
import "../../bar"

Item {
	id: root

	required property var layout
	property string part: "left"
	property bool ready: false

	readonly property var monitor: Yudae.screenActive || ({ width: 1920, height: 1080, scale: 1 })
	readonly property real screenWidth: Math.round(root.monitor.width / (root.monitor.scale || 1))
	readonly property real screenHeight: Math.round(root.monitor.height / (root.monitor.scale || 1))
	readonly property var bar: root.layout && root.layout.bar ? root.layout.bar : ({})
	readonly property var slots: root.bar.layout || ({})
	readonly property bool atBottom: root.bar.position === "bottom"
	readonly property real outer: Config.barFloating ? Config.gapsOut : 0
	readonly property real shot: Math.max(root.screenWidth, root.width)
	readonly property real shift: root.part === "left" ? 0 : root.part === "right" ? root.width - root.shot : Math.round((root.width - root.shot) / 2)
	readonly property int at: root.part === "left" ? 0 : root.part === "right" ? 2 : 1

	height: (loader.item ? loader.item.height : 0) + root.outer + Config.settingsPreviewBelow + 16

	function shiftPart(step) {
		root.part = ["left", "center", "right"][Calc.clamp(root.at + step, 0, 2)];
	}

	Item {
		id: surface

		anchors.fill: parent
		layer.enabled: true
		layer.effect: OpacityMask {
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
		sourceSize.width: root.shot * 2
		sourceSize.height: root.screenHeight * 2
		mipmap: true
		source: Yudae.wallpaper.active ? "file://" + Yudae.wallpaper.active : ""
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

	Timer {
		interval: 40
		running: true
		onTriggered: root.ready = true
	}

		MouseArea {
			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.AllButtons
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: 16
		color: "transparent"
		border.width: 1
		border.color: Config.settingsRule
		z: 2
	}

	Rectangle {
		id: mask

		anchors.fill: parent
		radius: 16
		visible: false
	}

	ArrowPill {
		visible: root.at > 0
		anchors.left: parent.left
		anchors.leftMargin: 14
		anchors.verticalCenter: parent.verticalCenter
		glyph: Config.iconChevron
		onClicked: root.shiftPart(-1)
	}

	ArrowPill {
		visible: root.at < 2
		anchors.right: parent.right
		anchors.rightMargin: 14
		anchors.verticalCenter: parent.verticalCenter
		glyph: Config.iconRight
		onClicked: root.shiftPart(1)
	}
}
