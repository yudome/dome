import QtQuick
import qs.ui
import qs.panelkit
import qs
import qs.services

ProcessPanel {
	id: root

	property var governors: root.source ? root.source.governors : []
	property string governor: root.source ? root.source.governor : ""
	property var battery: root.source ? root.source.battery : null
	property var awake: root.source ? root.source.awake : null

	readonly property color accentInk: Config.mono ? Config.powerBaseMono : Config.powerBase
	readonly property int governorIndex: Math.max(0, root.governors.indexOf(root.governor))
	readonly property var awakeModes: [
		{ value: "off", label: Config.iconAwakeOff, title: Config.powerAwakeOff },
		{ value: "auto", label: Config.iconAwakeAuto, title: Config.powerAwakeAuto },
		{ value: "on", label: Config.iconAwakeOn, title: Config.powerAwakeOn }
	]
	readonly property string awakeMode: root.awake && root.awake.mode ? root.awake.mode : "auto"
	readonly property int awakeIndex: Math.max(0, root.awakeModes.findIndex((entry) => entry.value === root.awakeMode))

	function governorGlyph(c, r, n, t, value) {
		const name = String(value).toLowerCase();
		if (name.indexOf("save") >= 0) {
			const k = c + Math.floor(t * (r === 0 ? 7 : 5));
			return Calc.hash(k, r, 0) > 0.82 ? (Calc.hash(k, r, 1) > 0.5 ? "z" : "Z") : " ";
		}
		const rush = name.indexOf("perf") >= 0;
		const ph = (((c + r * 2 - t * (rush ? 10 : 4)) % 4) + 4) % 4;
		if (ph < 1)
			return ">";
		return ph < 2 ? (rush ? ">" : "-") : " ";
	}

	function cycleAwake() {
		const next = root.awakeModes[(root.awakeIndex + 1) % root.awakeModes.length];

		root.awakePicked(next.value);
	}

	title: Config.powerGovernorTitle
	showTotal: true
	totalOverride: govStep.dragging ? String(govStep.shownValue) : root.governor
	totalInk: root.accentInk
	contentWidth: Config.powerTooltipWidth

	keyAction: function (event) {
		if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
			return false;

		root.cycleAwake();
		event.accepted = true;
		return true;
	}

	viz: [
		PowerFlow {
			visible: root.battery !== null
			width: parent.width
			height: Config.powerFlowHeight
			flow: root.source ? root.source.flow : 0
			watts: root.battery ? root.battery.watts || 0 : 0
			fill: root.battery ? root.battery.pct / 100 : 1
			hotInk: !Config.mono && root.battery && root.battery.color ? root.battery.color : root.accentInk
		},

		Slider {
			id: govStep

			width: parent.width
			label: Config.powerGovernorTitle
			stops: root.governors
			value: root.governors[root.governorIndex]
			onMoved: (next) => root.governorPicked(String(next))

			renderer: Component {
				GlyphScale {
					ink: root.accentInk
					glyph: root.governorGlyph
					animated: true
				}
			}
		},

		Separator {
			width: parent.width
		},

		Item {
			id: awakeRow

			readonly property bool armed: root.awakeMode !== "off"

			width: parent.width
			height: Math.max(awakeGlyph.implicitHeight, awakeTitle.implicitHeight, awakeSwitch.implicitHeight) + 8

			Icon {
				id: awakeGlyph

				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter

				size: Config.fontSize + 2
				ink: awakeRow.armed ? root.accentInk : Config.dim
				glyph: Config.iconAwake
			}

			Label {
				id: awakeTitle

				anchors.left: awakeGlyph.right
				anchors.leftMargin: 6
				anchors.right: awakeSwitch.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				elide: Text.ElideRight

				ink: awakeRow.armed ? Config.foreground : Config.dim
				text: root.awakeModes[root.awakeIndex].title
			}

			PillSwitch {
				id: awakeSwitch

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter

				model: root.awakeModes
				selected: root.awakeIndex
				ink: root.accentInk

				onPick: (value) => root.awakePicked(String(value))
			}
		}
	]

	signal governorPicked(string governor)
	signal awakePicked(string mode)
}
