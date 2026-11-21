pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Dialogs
import qs
import qs.ui

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
	readonly property var options: root.entry.options || []
	readonly property var stepList: root.entry.steps || []
	readonly property real controlWidth: Math.min(Config.settingsControlWidth, root.width * 0.5)
	readonly property real controlHeight: root.spot ? spots.height : root.numeric ? steps.implicitHeight : Config.settingsChipHeight

	width: parent ? parent.width : 0
	height: Math.max(Config.settingsRowHeight, labels.height + 20, root.controlHeight + 16)

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

	function nearest(v) {
		let best = 0;
		for (let i = 1; i < root.stepList.length; i++) {
			if (Math.abs(root.stepList[i] - v) < Math.abs(root.stepList[best] - v))
				best = i;
		}
		return best;
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
		anchors.rightMargin: Config.settingsGap
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
				text: root.entry.label
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
			visible: text !== ""
			wrapMode: Text.WordWrap
			maximumLineCount: 2
			elide: Text.ElideRight
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			color: Config.settingsLabel
			text: root.entry.note || ""
		}
	}

	Item {
		id: control

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: root.controlWidth
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
						radius: 3
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
			model: root.numeric ? root.stepList : []
			selected: root.numeric ? root.nearest(Number(root.value)) : -1
			ink: Config.settingsInk
			glyph: root.ruler
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
			width: 24
			height: 24
			size: Config.settingsFontSize + 5
			glyph: root.type === "glyph" ? root.value : ""
		}

		Rectangle {
			id: valueField

			visible: root.type !== "bool" && root.type !== "enum"
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			width: root.type === "text" ? parent.width : root.type === "color" || root.type === "glyph" ? 104 : 56
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
				text: root.show(root.value)

				Keys.onEscapePressed: input.focus = false
				onEditingFinished: {
					if (!root.commit(input.text))
						input.text = Qt.binding(function () { return root.show(root.value); });
				}
			}
		}
	}
}
