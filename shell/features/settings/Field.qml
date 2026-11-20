pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Dialogs
import qs
import qs.ui
import qs.services
import "Toml.js" as Toml

Item {
	id: root

	required property var entry
	property var value: root.entry.value
	property bool changed: false
	property bool last: false
	property var onSet

	readonly property string type: root.entry.type
	readonly property bool numeric: root.type === "int" || root.type === "float"
	readonly property bool spot: root.entry.key === "popupPos"
	readonly property var options: root.numeric ? Toml.steps(root.entry.value, root.type, root.entry.key) : (Toml.enums[root.entry.key] || [])
	readonly property string note: Toml.note(root.entry.comment)
	readonly property real controlHeight: root.spot ? spots.height : root.numeric ? steps.implicitHeight : Config.settingsChipHeight

	width: parent ? parent.width : 0
	height: Math.max(Config.settingsRowHeight, labels.height + 20, root.controlHeight + 16)

	function set(next) {
		if (root.onSet)
			root.onSet(next);
	}

	function show(v) {
		return root.type === "float" ? String(Number(Number(v).toFixed(3))) : String(v);
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

	function density(c, r, n) {
		const ramp = " .-+xXS#";
		const k = Math.floor((c + 0.5) / n * (ramp.length - 1) - (r === 1 ? 1.2 : 0) + Calc.hash(c, r, 0) * 0.8);
		return ramp[Calc.clamp(k, 1, ramp.length - 1)];
	}

	Rectangle {
		visible: !root.last
		anchors.bottom: parent.bottom
		width: parent.width
		height: 1
		color: Config.settingsRule
	}

	Column {
		id: labels

		anchors.left: parent.left
		anchors.right: control.left
		anchors.rightMargin: Config.settingsGap * 2
		anchors.verticalCenter: parent.verticalCenter
		spacing: 3

		Row {
			width: parent.width
			spacing: 8

			Text {
				id: nameText

				width: Math.min(implicitWidth, parent.width - 14)
				elide: Text.ElideRight
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize + 1
				color: Config.foreground
				text: Toml.label(root.entry.key, root.entry.section)
			}

			Rectangle {
				anchors.verticalCenter: nameText.verticalCenter
				width: 6
				height: 6
				radius: 3
				color: Config.settingsPending
				visible: root.changed
			}
		}

		Text {
			width: parent.width
			visible: root.note !== ""
			wrapMode: Text.WordWrap
			maximumLineCount: 2
			elide: Text.ElideRight
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			color: Config.settingsLabel
			text: root.note
		}
	}

	Item {
		id: control

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
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

		PillSwitch {
			visible: root.type === "enum" && !root.spot
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			model: root.type === "enum" && !root.spot ? root.options.map(function (o) { return { label: o.charAt(0).toUpperCase() + o.slice(1), value: o }; }) : []
			selected: root.options.indexOf(root.value)
			onPick: function (next) { root.set(next); }
		}

		Rectangle {
			id: spots

			readonly property var cells: ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"]

			visible: root.spot
			anchors.right: parent.right
			width: 120
			height: 72
			radius: 6
			color: Config.launcherSearchBox

			Repeater {
				model: root.spot ? spots.cells : []

				delegate: Item {
					id: cell

					required property string modelData
					required property int index

					readonly property bool chosen: root.value === cell.modelData

					x: (cell.index % 3) * spots.width / 3
					y: Math.floor(cell.index / 3) * spots.height / 2
					width: spots.width / 3
					height: spots.height / 2

					Rectangle {
						anchors.centerIn: parent
						width: cell.chosen ? 26 : 6
						height: cell.chosen ? 14 : 6
						radius: cell.chosen ? 3 : 3
						color: cell.chosen ? Config.foreground : (spotHover.containsMouse ? Config.settingsLabel : Config.dim)

						Behavior on width {
							NumberAnimation {
								duration: Config.toggleMs
								easing.type: Easing.OutCubic
							}
						}
					}

					MouseArea {
						id: spotHover

						anchors.fill: parent
						hoverEnabled: true
						onClicked: root.set(cell.modelData)
					}
				}
			}
		}

		GlyphBar {
			id: steps

			visible: root.numeric
			anchors.left: parent.left
			anchors.right: valueField.left
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			model: root.numeric ? root.options : []
			selected: root.numeric ? Toml.nearest(root.options, Number(root.value)) : -1
			ink: Config.settingsInk
			glyph: root.density
			follow: false
			onPick: function (next) { root.set(next); }
		}

		Rectangle {
			visible: root.type === "color"
			anchors.right: valueField.left
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			width: 22
			height: 22
			radius: 11
			color: root.type === "color" ? root.value : Config.surface
			border.width: 1
			border.color: Config.settingsRule

			MouseArea {
				anchors.fill: parent
				anchors.margins: -4
				cursorShape: Qt.PointingHandCursor
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
			anchors.right: valueField.left
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			width: 22
			height: 22
			size: Config.settingsFontSize + 4
			glyph: root.type === "glyph" ? root.value : ""
		}

		Rectangle {
			id: valueField

			visible: root.type !== "bool" && root.type !== "enum"
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			width: root.type === "text" ? parent.width : root.type === "color" ? 92 : root.type === "glyph" ? 48 : 52
			height: Config.settingsChipHeight
			radius: 6
			color: input.activeFocus || fieldHover.containsMouse || root.type === "text" ? Config.launcherSearchBox : "transparent"

			MouseArea {
				id: fieldHover

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.IBeamCursor
				onClicked: input.forceActiveFocus()
			}

			TextInput {
				id: input

				anchors.fill: parent
				anchors.leftMargin: 8
				anchors.rightMargin: 8
				verticalAlignment: TextInput.AlignVCenter
				horizontalAlignment: root.numeric ? TextInput.AlignRight : TextInput.AlignLeft
				clip: true
				selectByMouse: true
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize
				font.features: { "tnum": 1 }
				color: Config.foreground
				selectionColor: Config.settingsSelected
				text: root.numeric ? root.show(root.value) : String(root.value)

				Keys.onEscapePressed: input.focus = false
				onEditingFinished: {
					if (!root.commit(input.text))
						input.text = Qt.binding(function () { return root.numeric ? root.show(root.value) : String(root.value); });
				}
			}
		}
	}
}
