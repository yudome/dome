import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.ui
import qs
import qs.services
import "../features/agent"
import "../features/clock"
import "../features/github"
import "../features/cpu"
import "../features/media"
import "../features/memory"
import "../features/network"
import "../features/notify"
import "../features/power"
import "../features/spacer"
import "../features/tray"
import "../features/volume"
import "../features/weather"
import "../features/workspaces"

Item {
	id: body

	property var host: null
	property var layout: ({ position: "top", centerAnchor: "", left: [], center: [], right: [] })
	property bool hidden: false
	property real contentFade: 1
	property bool clear: false
	property var widgets: ({})

	readonly property real inset: border.inset
	readonly property real contentHeight: Math.max(leftRow.implicitHeight, centerRow.implicitHeight, rightRow.implicitHeight)
	readonly property var centerItem: body.widgets[body.layout.centerAnchor]
	readonly property var centerSlot: body.centerItem && body.centerItem.parent && body.centerItem.parent.parent === centerRow ? body.centerItem.parent : null

	signal backgroundClicked()
	signal backgroundDoubleClicked()

	implicitHeight: Math.ceil(body.contentHeight) + 2 * border.inset

	function componentFor(id) {
		if (id === "workspaces") return workspacesComponent;
		if (id === "clock") return clockComponent;
		if (id === "weather") return weatherComponent;
		if (id === "notify") return notifyComponent;
		if (id === "github") return githubComponent;
		if (id === "tray") return trayComponent;
		if (id === "cpu") return cpuComponent;
		if (id === "memory") return memoryComponent;
		if (id === "media") return mediaComponent;
		if (id === "network") return networkComponent;
		if (id === "volume") return volumeComponent;
		if (id === "power") return powerComponent;
		if (id === "agent") return agentComponent;
		if (id === "spacer") return spacerComponent;

		return null;
	}

	function isCenterSlot(id) {
		const center = body.layout.center;

		return center !== undefined && center !== null && center.some(function (entry) {
			return entry && entry.id === id;
		});
	}

	function register(id, item) {
		const next = Object.assign({}, body.widgets);

		next[id] = item;
		body.widgets = next;
	}

	function unregister(id) {
		if (body.widgets[id] === undefined)
			return;

		const next = Object.assign({}, body.widgets);

		delete next[id];
		body.widgets = next;
	}

	Component { id: workspacesComponent; Workspaces {} }
	Component { id: clockComponent; Clock {} }
	Component { id: weatherComponent; WeatherStat {} }
	Component { id: notifyComponent; NotifyStat {} }
	Component { id: githubComponent; ContribStat {} }
	Component { id: trayComponent; Tray {} }
	Component { id: cpuComponent; CpuStat {} }
	Component { id: memoryComponent; MemoryStat {} }
	Component { id: mediaComponent; MediaStat {} }
	Component { id: networkComponent; NetworkStat {} }
	Component { id: volumeComponent; VolumeStat {} }
	Component { id: powerComponent; PowerStat {} }
	Component { id: agentComponent; AgentStat {} }
	Component { id: spacerComponent; Spacer {} }

	Component {
		id: slotDelegate

		Loader {
			required property var modelData
			required property int index

			sourceComponent: body.componentFor(modelData.id)
			visible: !item || item.wanted === undefined ? true : item.wanted
			anchors.bottom: parent.bottom
			anchors.bottomMargin: item ? item.baselineLift : 0

			onLoaded: {
				if (item.settings !== undefined)
					item.settings = modelData;
				if (item.mode !== undefined && modelData.mode !== undefined)
					item.mode = modelData.mode;
				if (item.bar !== undefined)
					item.bar = body.host;
				if (item.popupCentered !== undefined && body.isCenterSlot(modelData.id)) {
					item.popupCentered = true;
					if (item.popupAlwaysCentered !== undefined)
						item.popupAlwaysCentered = true;
				}
				body.register(modelData.id, item);
			}

			Component.onDestruction: body.unregister(modelData.id)
		}
	}

	Rectangle {
		anchors.fill: parent
		color: body.clear ? "transparent" : Config.surfaceTranslucent

		Behavior on color {
			ColorAnimation {
				duration: Config.barFadeMs
				easing.type: Easing.BezierSpline
				easing.bezierCurve: [0.15, 0, 0.1, 1, 1, 1]
			}
		}
	}

	HyprBorder {
		id: border

		visible: !body.hidden
		opacity: body.contentFade
		anchors.fill: parent
		padding: Config.barInset
		borderWidth: Config.barBorderWidth
		shadowEnabled: false
		backgroundColor: "transparent"
	}

	MouseArea {
		anchors.fill: parent
		visible: !body.hidden
		opacity: body.contentFade

		onClicked: body.backgroundClicked()
		onDoubleClicked: body.backgroundDoubleClicked()
	}

	Row {
		id: leftRow

		visible: !body.hidden
		opacity: body.contentFade
		anchors.left: parent.left
		anchors.leftMargin: border.inset + Config.barPadding
		anchors.bottom: parent.bottom
		anchors.bottomMargin: border.inset
		spacing: Config.spacing

		Repeater {
			model: body.layout.left
			delegate: slotDelegate
		}
	}

	Row {
		id: centerRow

		visible: !body.hidden
		opacity: body.contentFade
		anchors.bottom: parent.bottom
		anchors.bottomMargin: border.inset
		spacing: Config.spacing
		x: Math.round(body.width / 2 - (body.centerSlot ? body.centerSlot.x + body.centerSlot.width / 2 : centerRow.width / 2))

		Repeater {
			model: body.layout.center
			delegate: slotDelegate
		}
	}

	Row {
		id: rightRow

		visible: !body.hidden
		opacity: body.contentFade
		anchors.right: parent.right
		anchors.rightMargin: border.inset + Config.barPadding
		anchors.bottom: parent.bottom
		anchors.bottomMargin: border.inset
		spacing: Config.barStatSpacing

		Repeater {
			model: body.layout.right
			delegate: slotDelegate
		}
	}
}
