pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Dialogs
import qs
import qs.ui
import "Toml.js" as Toml

Item {
	id: root

	required property var entry
	property var value: root.entry.value
	property bool changed: false
	property var onSet

	readonly property string type: root.entry.type
	readonly property bool numeric: root.type === "int" || root.type === "float"
	readonly property var options: root.numeric ? Toml.steps(root.entry.value, root.type) : (Toml.enums[root.entry.key] || [])
	readonly property string note: /[()?"+*]/.test(root.entry.comment) || /^same as/.test(root.entry.comment) ? "" : root.entry.comment
	readonly property real controlHeight: root.type === "enum" ? enumList.height : Config.settingsRowHeight

	width: parent ? parent.width : 0
	height: Math.max(labels.height, root.controlHeight) + Config.settingsGap / 2

	function set(next) {
		if (root.onSet)
			root.onSet(next);
	}

	function label(key) {
		const words = key.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z])([A-Z][a-z])/g, "$1 $2").toLowerCase();
		return words.charAt(0).toUpperCase() + words.slice(1);
	}

	function show(v) {
		if (root.type === "float")
			return String(Number(Number(v).toFixed(4)));
		return String(v);
	}

	function commit(text) {
		if (root.numeric) {
			const n = Number(text);
			if (text.trim() === "" || !isFinite(n))
				return false;
			root.set(root.type === "int" ? Math.round(n) : n);
			return true;
		}
		if (root.type === "color" && !/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(text))
			return false;
		root.set(text);
		return true;
	}

	Rectangle {
		id: mark

		y: labels.y + nameText.height / 2 - 3
		width: 6
		height: 6
		radius: 3
		color: Config.settingsPending
		visible: root.changed
	}

	Column {
		id: labels

		anchors.left: parent.left
		anchors.leftMargin: 14
		anchors.right: control.left
		anchors.rightMargin: Config.settingsGap
		y: root.type === "enum" ? 6 : Math.max(0, (root.controlHeight - labels.height) / 2)
		spacing: 2

		Text {
			id: nameText

			width: parent.width
			elide: Text.ElideRight
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsFontSize
			color: Config.foreground
			text: root.label(root.entry.key)
		}

		Text {
			id: noteText

			width: parent.width
			elide: Text.ElideRight
			visible: root.note !== ""
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			color: Config.settingsLabel
			text: root.note
		}
	}

	Item {
		id: control

		anchors.right: parent.right
		anchors.top: parent.top
		width: Config.settingsControlWidth
		height: root.controlHeight

		PillSwitch {
			visible: root.type === "bool"
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			model: [{ label: "Off", value: false }, { label: "On", value: true }]
			selected: root.value === true ? 1 : 0
			onPick: function (next) { root.set(next); }
		}

		Selector {
			id: enumList

			visible: root.type === "enum"
			anchors.right: parent.right
			width: parent.width
			visibleRows: Math.max(1, root.options.length)
			rowHeight: Config.launcherRowHeight
			scrollWidth: 0
			model: root.type === "enum" ? root.options : []
			currentIndex: root.options.indexOf(root.value)

			delegate: Item {
				id: option

				required property var modelData

				width: enumList.rowWidth
				height: enumList.rowHeight

				Text {
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					elide: Text.ElideRight
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsFontSize
					color: option.modelData === root.value ? Config.launcherHighlightText : Config.settingsLabel
					text: option.modelData
				}

				MouseArea {
					anchors.fill: parent
					onClicked: root.set(option.modelData)
				}
			}
		}

		StepBar {
			visible: root.numeric
			anchors.left: parent.left
			anchors.right: valueBox.left
			anchors.rightMargin: Config.settingsGap
			anchors.verticalCenter: parent.verticalCenter
			model: root.numeric ? root.options : []
			selected: root.numeric ? Toml.nearest(root.options, Number(root.value)) : -1
			ink: Config.settingsAccent
			follow: false
			onPick: function (next) { root.set(next); }
		}

		Rectangle {
			id: swatch

			visible: root.type === "color"
			anchors.right: valueBox.left
			anchors.rightMargin: Config.settingsGap
			anchors.verticalCenter: parent.verticalCenter
			width: Config.settingsChipHeight
			height: Config.settingsChipHeight - 6
			radius: Config.rowRadius
			color: root.type === "color" ? root.value : Config.surface
			border.width: 1
			border.color: Config.dim

			MouseArea {
				anchors.fill: parent
				onClicked: picker.open()
			}
		}

		ColorDialog {
			id: picker

			selectedColor: root.type === "color" ? root.value : Config.surface
			options: ColorDialog.ShowAlphaChannel
			onAccepted: {
				const c = picker.selectedColor;
				const hex = (n) => ("0" + Math.round(n * 255).toString(16)).slice(-2);
				root.set(String(root.value).length === 9 ? "#" + hex(c.a) + hex(c.r) + hex(c.g) + hex(c.b) : "#" + hex(c.r) + hex(c.g) + hex(c.b));
			}
		}

		Glyph {
			visible: root.type === "glyph"
			anchors.right: valueBox.left
			anchors.rightMargin: Config.settingsGap
			anchors.verticalCenter: parent.verticalCenter
			width: Config.settingsChipHeight
			height: Config.settingsChipHeight
			size: Config.settingsFontSize + 4
			glyph: root.type === "glyph" ? root.value : ""
		}

		Rectangle {
			id: valueBox

			visible: root.type !== "bool" && root.type !== "enum"
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			width: root.type === "text" ? parent.width : (root.type === "glyph" ? 56 : 92)
			height: Config.settingsChipHeight - 6
			radius: Config.rowRadius
			color: Config.launcherSearchBox
			border.width: input.activeFocus ? 1 : 0
			border.color: input.acceptableInput ? Config.settingsAccent : Config.red

			TextInput {
				id: input

				anchors.fill: parent
				anchors.leftMargin: 8
				anchors.rightMargin: 8
				verticalAlignment: TextInput.AlignVCenter
				clip: true
				selectByMouse: true
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize
				color: Config.foreground
				selectionColor: Config.settingsSelected
				text: root.numeric ? root.show(root.value) : String(root.value)

				onEditingFinished: {
					if (!root.commit(input.text))
						input.text = Qt.binding(function () { return root.numeric ? root.show(root.value) : String(root.value); });
				}
			}
		}
	}
}
