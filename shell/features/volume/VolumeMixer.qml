import QtQuick
import qs.ui
import qs.panelkit
import qs
import qs.services

PanelPage {
	id: root

	readonly property var mix: Yudae.audio
	readonly property var nodes: root.mix.nodes || []
	readonly property bool onScreen: root.Window.window ? root.Window.window.visible : false

	property int targetIndex: 0

	property bool shown: false
	property bool compact: false
	property bool keyboard: false
	property bool shift: false
	readonly property bool showApps: (root.mix.streams || []).length > 0 && !root.compact
	readonly property var globalNode: root.nodeOf(root.mix.sink)
	readonly property var sinks: root.compact ? [] : (root.mix.sinks || [])
	readonly property var deviceRows: root.sinks.map((sink) => root.nodeOf(sink.id)).filter((node) => node !== null)
	readonly property var appRows: root.showApps ? (root.mix.streams || []).map(root.nodeOf).filter((node) => node !== null) : []
	readonly property int globalOffset: root.globalNode !== null ? 1 : 0
	readonly property var rows: root.globalNode !== null
		? [root.globalNode].concat(root.appRows).concat(root.deviceRows)
		: root.appRows.concat(root.deviceRows)

	onOnScreenChanged: Yudae.cmd("audio", { watch: { on: root.onScreen === true } })

	onShownChanged: {
		if (root.shown) {
			root.forceActiveFocus();

			return;
		}

		root.keyboard = false;
		root.shift = false;
		root.pending = { id: -1, volume: -1 };
	}

	readonly property var steps: Array(Config.mixerStepCount).fill(1)

	contentWidth: Config.mixerWidth

	readonly property var selectedNode: root.rows.length > 0
		? root.rows[Calc.clamp(root.targetIndex, 0, root.rows.length - 1)]
		: null

	function moveTarget(step) {
		const last = root.rows.length - 1;

		if (last < 0)
			return;

		root.targetIndex = Calc.clamp(root.targetIndex + step, 0, last);
	}

	function focusNode(node) {
		for (let i = 0; i < root.rows.length; i++) {
			if (node !== null && root.rows[i] === node) {
				root.targetIndex = i;

				return;
			}
		}
	}

	function nodeOf(id) {
		for (let i = 0; i < root.nodes.length; i++) {
			if (root.nodes[i].id === id)
				return root.nodes[i];
		}

		return null;
	}

	function setFader(node, fraction) {
		if (!node)
			return;

		root.focusNode(node);

		const level = Calc.clamp(fraction, 0, Config.mixerMaxVolume);

		if (!isFinite(level))
			return;

		if (node.volume !== undefined && Math.abs(root.volumeOf(node) - level) < 0.004)
			return;

		root.pending = { id: node.id, volume: level };
		settle.restart();
		Yudae.cmd("audio", { volume: { id: node.id, level: level } });
	}

	function beginDrag(node, fader, position) {
		const origin = fader.mapToItem(root, 0, 0);

		root.drag = { id: node ? node.id : -1, from: origin.x, width: fader.width, last: -1 };
	}

	function dragFader(node, fader, bar, position, modifiers) {
		if (!node || !fader || !bar || root.drag.id !== node.id || !(root.drag.width > 0))
			return;

		root.keyboard = false;

		const at = fader.mapToItem(root, position, 0).x - root.drag.from;

		if (!isFinite(at))
			return;

		if (root.drag.last >= 0 && Math.abs(at - root.drag.last) > root.drag.width / 2)
			return;

		root.drag = { id: root.drag.id, from: root.drag.from, width: root.drag.width, last: at };

		const fraction = Calc.clamp(at / root.drag.width, 0, 1);
		const shift = (modifiers & Qt.ShiftModifier) !== 0;

		root.shift = shift;
		root.setFader(node, shift ? fraction : (bar.indexAt(at, 0) + 1) / bar.count);
	}

	function nudgeVolume(step) {
		const node = root.selectedNode;

		if (!node)
			return;

		root.setFader(node, Calc.clamp(root.volumeOf(node) + step, 0, Config.mixerMaxVolume));
	}

	Keys.onPressed: function (event) {
		if (event.key === Qt.Key_Shift)
			root.shift = true;

		if (Input.direction(event) !== "")
			root.keyboard = true;

		Input.mixer(event, root);
	}

	Keys.onReleased: function (event) {
		if (event.key === Qt.Key_Shift)
			root.shift = false;
	}

	function toggleMute(node) {
		if (!node)
			return;

		Yudae.cmd("audio", { mute: { id: node.id, muted: node.muted !== true } });
	}

	function iconFor(node) {
		if (!node)
			return "";

		return AppIcons.iconOf(node.appId, node.appIds);
	}

	function makeDefault(node) {
		if (!node)
			return;

		Yudae.cmd("audio", { default: { id: node.id } });
	}

	function activateNode(node) {
		if (!node || !node.isSink)
			return;

		root.makeDefault(node);
	}

	property var drag: ({ id: -1, from: 0, width: 0, last: -1 })
	property var pending: ({ id: -1, volume: -1 })

	onMixChanged: root.reconcile()

	Timer {
		id: settle

		interval: Config.mixerPendingMs
		onTriggered: root.pending = { id: -1, volume: -1 }
	}

	function volumeOf(node) {
		if (!node)
			return 0;

		if (root.pending.id === node.id)
			return root.pending.volume;

		return node.volume;
	}

	function reconcile() {
		if (root.pending.id < 0)
			return;

		const node = root.nodeOf(root.pending.id);

		if (!node || Math.abs(node.volume - root.pending.volume) < 0.004)
			root.pending = { id: -1, volume: -1 };
	}

	component MixRow: PanelRow {
		id: row

		property var node
		property int rowIndex: -1
		property bool global: false

		readonly property bool stream: !!row.node && row.node.isStream === true
		readonly property bool muted: !!row.node && row.node.muted === true
		readonly property real volume: root.volumeOf(row.node)
		readonly property string iconSource: row.stream ? root.iconFor(row.node) : ""
		readonly property real level: Calc.clamp(row.volume / Config.mixerMaxVolume, 0, 1)
		readonly property int step: Math.round(row.level * Config.mixerStepCount) - 1
		readonly property real hoverPad: Math.max(0, (row.height - Config.mixerFaderThickness) / 2)

		selected: row.rowIndex === root.targetIndex && root.keyboard
		dim: row.muted

		onActivated: {
			root.keyboard = false;
			root.targetIndex = row.rowIndex;
			root.activateNode(row.node);
		}

		leading: Component {
			Icon {
				size: Config.mixerIconSize
				opacity: row.muted ? Config.disabledOpacity : 1
				source: row.iconSource
				glyph: row.iconSource === "" ? (row.stream ? Config.iconApp : Config.iconVolumeHigh) : ""
				ink: row.ink
			}
		}

		body: Item {
			id: fader

			anchors.fill: parent
			anchors.rightMargin: Config.mixerListGap

			StepBar {
				id: faderBar

				anchors.verticalCenter: parent.verticalCenter
				anchors.left: parent.left
				anchors.right: parent.right
				height: Config.mixerFaderThickness
				model: root.steps
				follow: false
				hitPad: row.hoverPad
				selected: row.step
				level: root.shift ? row.level : -1
				lens: false
				ink: row.muted && !row.hot ? Config.dim : Config.foreground
			}

			MouseArea {
				anchors.fill: parent
				preventStealing: true

				onPressed: mouse => {
					root.beginDrag(row.node, fader, mouse.x);
					root.dragFader(row.node, fader, faderBar, mouse.x, mouse.modifiers);
				}
				onPositionChanged: mouse => root.dragFader(row.node, fader, faderBar, mouse.x, mouse.modifiers)
			}
		}
	}

	Column {
		id: body

		width: root.contentWidth
		spacing: Config.mixerChannelGap

		PanelHeader {
			width: parent.width
			visible: !root.compact && root.rows.length > 0
			title: "Sound"
		}

		MixRow {
			width: parent.width
			node: root.globalNode
			rowIndex: 0
			global: true
			visible: root.globalNode !== null
		}

		Repeater {
			model: root.appRows

			delegate: MixRow {
				required property var modelData
				required property int index

				width: parent.width
				node: modelData
				rowIndex: root.globalOffset + index
			}
		}

		Separator {
			width: body.width
			color: Config.rule
			visible: !root.compact && root.deviceRows.length > 0 && root.appRows.length > 0
		}

		PanelHeader {
			width: parent.width
			visible: !root.compact && root.deviceRows.length > 0
			title: "Output"
		}

		Repeater {
			model: root.deviceRows

			delegate: PanelRow {
				id: device

				required property var modelData
				required property int index

				readonly property int rowIndex: root.globalOffset + root.appRows.length + device.index

				width: parent.width
				glyph: Config.iconOutput
				title: device.modelData.description || device.modelData.name || ""
				current: device.modelData.isDefault === true
				dim: device.modelData.muted === true
				selected: device.rowIndex === root.targetIndex && root.keyboard

				onActivated: {
					root.keyboard = false;
					root.targetIndex = device.rowIndex;
					root.activateNode(device.modelData);
				}
			}
		}
	}
}
