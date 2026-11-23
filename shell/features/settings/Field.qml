pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui

FormRow {
	id: root

	required property var entry
	property var value: root.entry.value
	property bool changed: false
	property var onSet

	readonly property string type: root.entry.type
	readonly property bool numeric: root.type === "int" || root.type === "float"
	readonly property bool spot: root.entry.key === "popupPos"
	readonly property var options: root.entry.options || []
	readonly property var stepList: root.entry.steps || []
	readonly property real valueWidth: Config.appChipHeight * 2

	width: parent ? parent.width : 0
	label: root.entry.label
	note: root.entry.note || ""
	pending: root.changed
	controlHeight: root.spot ? spots.implicitHeight : root.numeric ? slider.implicitHeight : Config.appChipHeight

	function set(next) {
		if (root.onSet)
			root.onSet(next);
	}

	function show(v) {
		if (root.type === "float")
			return String(Number(Number(v).toFixed(3)));
		if (root.type === "glyph")
			return root.code(String(v));
		return String(v);
	}

	function code(text) {
		const point = text.codePointAt(0) || 0;
		const hex = point.toString(16).toUpperCase();
		return point > 0xffff ? "\\U" + ("00000000" + hex).slice(-8) : "\\u" + ("0000" + hex).slice(-4);
	}

	function commit(text) {
		if (root.numeric) {
			const n = Number(text);
			if (text.trim() === "" || !isFinite(n))
				return false;
			root.set(root.type === "int" ? Math.round(n) : n);
			return true;
		}
		if (root.type === "glyph") {
			const m = text.trim().match(/^\\[uU]([0-9a-fA-F]{4,8})$/);
			if (m)
				root.set(String.fromCodePoint(parseInt(m[1], 16)));
			else if (text.trim().length > 0)
				root.set(text.trim());
			else
				return false;
			return true;
		}
		root.set(text);
		return true;
	}

	function ruler(c, r, n) {
		if (r === 0)
			return c % 4 === 0 ? "|" : "'";
		return c === n - 1 ? ">" : "=";
	}

	Switch {
		visible: root.type === "bool"
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		label: root.entry.label
		checked: root.value === true
		onToggled: function (checked) { root.set(checked); }
	}

	PillSwitch {
		visible: root.type === "enum" && !root.spot && root.options.length <= 4
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		model: visible ? root.options.map(function (o) { return { label: o.charAt(0).toUpperCase() + o.slice(1), value: o }; }) : []
		selected: root.options.indexOf(root.value)
		onPick: function (next) { root.set(next); }
	}

	Select {
		visible: root.type === "enum" && !root.spot && root.options.length > 4
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		label: root.entry.label
		options: visible ? root.options : []
		value: root.value
		onPicked: function (next) { root.set(next); }
	}

	PositionPicker {
		id: spots

		visible: root.spot
		anchors.right: parent.right
		value: root.value
		onPicked: function (next) { root.set(next); }
	}

	Slider {
		id: slider

		visible: root.numeric
		anchors.left: parent.left
		anchors.right: valueField.left
		anchors.rightMargin: Config.appGap
		anchors.verticalCenter: parent.verticalCenter
		label: root.entry.label
		stops: root.numeric ? root.stepList : []
		value: Number(root.value)
		onMoved: function (next) { root.set(next); }

		renderer: Component {
			GlyphScale {
				glyph: root.ruler
			}
		}
	}

	Icon {
		visible: root.type === "glyph"
		anchors.right: valueField.left
		anchors.rightMargin: Config.appGap
		anchors.verticalCenter: parent.verticalCenter
		width: Config.appTitleSize
		height: Config.appTitleSize
		size: Config.fontSize + 4
		glyph: root.type === "glyph" ? root.value : ""
	}

	ColorField {
		visible: root.type === "color"
		anchors.fill: parent
		label: root.entry.label
		value: root.type === "color" ? root.value : ""
		onPicked: function (next) { root.set(next); }
	}

	TextField {
		id: valueField

		visible: root.type !== "bool" && root.type !== "enum" && root.type !== "color"
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: root.type === "text" ? parent.width : root.type === "glyph" ? Config.appControlWidth / 2.5 : root.valueWidth
		numeric: root.numeric
		boxed: root.type === "text"
		label: root.entry.label
		text: root.show(slider.dragging ? slider.shownValue : root.value)
		accept: root.commit
	}
}
