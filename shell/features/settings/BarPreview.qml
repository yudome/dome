import QtQuick
import qs
import qs.ui
import qs.services
import "../../bar"

Rectangle {
	id: root

	required property var layout
	property string part: "left"

	readonly property var monitor: Yudae.screenActive || ({ width: 1920, height: 1080, scale: 1 })
	readonly property real screenWidth: Math.round(root.monitor.width / (root.monitor.scale || 1))
	readonly property real screenHeight: Math.round(root.monitor.height / (root.monitor.scale || 1))
	readonly property var bar: root.layout && root.layout.bar ? root.layout.bar : ({})
	readonly property var slots: root.bar.layout || ({})
	readonly property bool atBottom: root.bar.position === "bottom"
	readonly property real outer: Config.barFloating ? Config.gapsOut : 0
	readonly property real span: Math.min(strip.width, root.screenWidth)
	readonly property real offset: root.part === "left" ? 0 : root.part === "right" ? root.screenWidth - root.span : Math.round((root.screenWidth - root.span) / 2)

	height: header.height + strip.height + Config.settingsGap * 2 + 12
	radius: Config.settingsRadius
	color: Config.settingsCard

	Item {
		id: header

		x: Config.settingsGap + 4
		y: Config.settingsGap
		width: root.width - x * 2
		height: partSwitch.height

		Text {
			anchors.left: parent.left
			anchors.right: partSwitch.left
			anchors.rightMargin: Config.settingsGap
			anchors.verticalCenter: parent.verticalCenter
			elide: Text.ElideRight
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsFontSize + 1
			color: Config.foreground
			text: "Preview"
		}

		PillSwitch {
			id: partSwitch

			anchors.right: parent.right
			model: [{ label: "Left", value: "left" }, { label: "Center", value: "center" }, { label: "Right", value: "right" }]
			selected: ["left", "center", "right"].indexOf(root.part)
			onPick: function (next) { root.part = next; }
		}
	}

	Rectangle {
		id: strip

		x: 6
		y: header.y + header.height + 12
		width: root.width - 12
		height: body.height + root.outer + Config.settingsPreviewBelow
		radius: Config.settingsRadius - 4
		color: Config.surface
		clip: true

		Image {
			x: -root.offset
			y: root.atBottom ? -(root.screenHeight - strip.height) : 0
			width: root.screenWidth
			height: root.screenHeight
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			sourceSize.width: root.screenWidth
			source: Yudae.wallpaper.active ? "file://" + Yudae.wallpaper.active : ""
		}

		BarBody {
			id: body

			x: root.outer - root.offset
			y: root.atBottom ? strip.height - height - root.outer : root.outer
			width: root.screenWidth - root.outer * 2
			height: implicitHeight
			layout: ({
				position: root.bar.position || "top",
				centerAnchor: root.bar.centerAnchor || "",
				left: root.slots.left || [],
				center: root.slots.center || [],
				right: root.slots.right || []
			})
			clear: root.bar.transparent === true
		}

		MouseArea {
			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.AllButtons
			onWheel: function (wheel) { wheel.accepted = false; }
		}
	}
}
