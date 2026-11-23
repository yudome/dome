pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.services

Item {
	id: root

	property real from: 0
	property real to: 1
	property real stepSize: 0
	property var stops: []
	property var value: 0
	property int orientation: Qt.Horizontal
	property string label: ""
	property Component renderer: defaultTrack

	signal moved(var value)

	property real dragNormalized: -1
	property real held: -1
	property bool engaged: false

	readonly property int stopCount: root.stops ? root.stops.length : 0
	readonly property bool horizontal: root.orientation === Qt.Horizontal
	readonly property bool dragging: hit.pressed && root.dragNormalized >= 0
	readonly property bool hovered: hit.containsMouse
	readonly property real valueNormalized: root.normalize(root.value)
	readonly property real normalized: root.dragging ? root.snap(root.dragNormalized) : root.held >= 0 ? root.held : root.valueNormalized
	readonly property var shownValue: root.valueAt(root.normalized)
	readonly property var shownStop: root.stopCount > 0 ? root.stops[root.indexAt(root.normalized)] : root.shownValue

	implicitWidth: root.horizontal ? Config.appControlWidth : Config.appChipHeight
	implicitHeight: root.horizontal ? (view.item ? view.item.implicitHeight : Config.appChipHeight) : Config.appControlWidth
	activeFocusOnTab: root.enabled
	opacity: root.enabled ? 1 : Config.disabledOpacity

	Accessible.role: Accessible.Slider
	Accessible.name: root.label

	onValueChanged: root.held = -1

	function stopValue(entry) {
		return entry !== null && entry !== undefined && entry.value !== undefined ? entry.value : entry;
	}

	function nearestStop(v) {
		let best = 0;
		for (let i = 0; i < root.stopCount; i++) {
			const s = root.stopValue(root.stops[i]);
			if (s === v)
				return i;
			if (Math.abs(Number(s) - Number(v)) < Math.abs(Number(root.stopValue(root.stops[best])) - Number(v)))
				best = i;
		}
		return best;
	}

	function indexAt(n) {
		return root.stopCount > 1 ? Math.round(n * (root.stopCount - 1)) : 0;
	}

	function normalize(v) {
		if (root.stopCount > 0)
			return root.stopCount > 1 ? root.nearestStop(v) / (root.stopCount - 1) : 0;
		return root.to > root.from ? Calc.clamp((Number(v) - root.from) / (root.to - root.from), 0, 1) : 0;
	}

	function snap(n) {
		if (root.stopCount > 1)
			return root.indexAt(n) / (root.stopCount - 1);
		if (root.stepSize > 0 && root.to > root.from) {
			const steps = (root.to - root.from) / root.stepSize;
			return Math.round(n * steps) / steps;
		}
		return n;
	}

	function valueAt(n) {
		if (root.stopCount > 0)
			return root.stopValue(root.stops[root.indexAt(n)]);
		const v = root.from + n * (root.to - root.from);
		return root.stepSize > 0 ? Number((Math.round(v / root.stepSize) * root.stepSize).toFixed(6)) : v;
	}

	function commit(n) {
		const at = root.snap(Calc.clamp(n, 0, 1));
		const next = root.valueAt(at);
		if (next === root.value)
			return;
		root.held = at;
		root.moved(next);
	}

	function unit() {
		if (root.stopCount > 1)
			return 1 / (root.stopCount - 1);
		if (root.stepSize > 0 && root.to > root.from)
			return root.stepSize / (root.to - root.from);
		return 0.01;
	}

	function nudge(steps) {
		root.commit(root.normalized + steps * root.unit());
	}

	function at(x, y) {
		return root.horizontal ? Calc.clamp(x / Math.max(1, root.width), 0, 1) : Calc.clamp(1 - y / Math.max(1, root.height), 0, 1);
	}

	Keys.onLeftPressed: root.nudge(-1)
	Keys.onDownPressed: root.nudge(-1)
	Keys.onRightPressed: root.nudge(1)
	Keys.onUpPressed: root.nudge(1)
	Keys.onPressed: function (event) {
		if (event.key === Qt.Key_Home)
			root.commit(0);
		else if (event.key === Qt.Key_End)
			root.commit(1);
		else if (event.key === Qt.Key_PageUp)
			root.nudge(Math.max(1, Math.round(0.1 / root.unit())));
		else if (event.key === Qt.Key_PageDown)
			root.nudge(-Math.max(1, Math.round(0.1 / root.unit())));
		else
			return;
		event.accepted = true;
	}

	Loader {
		id: view

		anchors.fill: parent
		sourceComponent: root.renderer
	}

	Binding {
		when: view.item !== null
		target: view.item
		property: "value"
		value: root.shownValue
	}

	Binding {
		when: view.item !== null
		target: view.item
		property: "normalized"
		value: root.normalized
	}

	Binding {
		when: view.item !== null
		target: view.item
		property: "dragging"
		value: root.dragging
	}

	Binding {
		when: view.item !== null
		target: view.item
		property: "hovered"
		value: root.hovered
	}

	Binding {
		when: view.item !== null
		target: view.item
		property: "orientation"
		value: root.orientation
	}

	Binding {
		when: view.item !== null
		target: view.item
		property: "stops"
		value: root.stops
	}

	FocusRing {}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		preventStealing: true
		enabled: root.enabled
		cursorShape: Qt.PointingHandCursor

		onPressed: function (mouse) {
			root.engaged = true;
			root.dragNormalized = root.at(mouse.x, mouse.y);
		}
		onPositionChanged: function (mouse) {
			if (pressed)
				root.dragNormalized = root.at(mouse.x, mouse.y);
		}
		onReleased: function (mouse) {
			root.commit(root.at(mouse.x, mouse.y));
			root.dragNormalized = -1;
		}
		onCanceled: root.dragNormalized = -1
		onExited: root.engaged = false
		onWheel: function (wheel) {
			const d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x;
			if (!root.engaged && !root.activeFocus || d === 0) {
				wheel.accepted = false;
				return;
			}
			root.nudge(d > 0 ? 1 : -1);
		}
	}

	Component {
		id: defaultTrack

		SliderTrack {}
	}
}
