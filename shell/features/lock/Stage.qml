pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs
import qs.services
import qs.ui

Rectangle {
	id: root

	property var source
	property int focusIndex: 0
	property bool reveal: false

	signal focusPicked(int index)
	signal revealPicked(bool shown)

	readonly property string mode: root.source ? root.source.mode : "locked"
	readonly property string message: root.source ? root.source.message : ""
	readonly property int filled: root.source ? root.source.filled : 0

	readonly property var actions: [
		{ glyph: Config.iconPowerOff, command: ["systemctl", "poweroff"] },
		{ glyph: Config.iconReboot, command: ["systemctl", "reboot"] }
	]
	readonly property bool switchable: !!root.source && !!root.source.switchable
	readonly property int slotCount: 2 + root.actions.length + (root.switchable ? 1 : 0)
	readonly property int switchSlot: 2 + root.actions.length
	property bool choiceOpen: false
	property int choiceRow: 0
	readonly property int panelWidth: Math.min(30, root.cols - 2)
	readonly property int panelCol: root.centerCol(root.panelWidth)
	readonly property int panelRow: root.topRow + 10

	readonly property int boxWidth: {
		const room = (root.cols - 2) - ((root.cols - 2) % 2);

		return Math.max(14, Math.min(root.clockRows[0].length, room));
	}
	readonly property int fieldOffset: Math.floor((root.fieldWidth - root.field.length) / 2)
	property bool blink: true
	readonly property int fieldWidth: root.boxWidth - 9
	readonly property int fontPixels: Math.round(Config.lockFontSize * 4 / 3)
	readonly property real cellWidth: Math.max(1, cell.averageCharacterWidth)
	readonly property real cellHeight: Math.max(1, Math.ceil(cell.height))
	readonly property int cols: Math.floor(root.width / root.cellWidth)
	readonly property int rows: Math.floor(root.height / root.cellHeight)
	readonly property int topRow: Math.max(0, Math.floor((root.rows - 11) / 2))
	readonly property int boxCol: root.centerCol(root.boxWidth)
	readonly property var clockRows: root.blockRows(Qt.formatTime(stamp.date, Config.lockClockFormat))
	readonly property int powerCol: root.centerCol((root.slotCount - 2) * 4 - 1)
	readonly property int powerRow: Math.max(0, root.rows - 2)
	readonly property string field: {
		const text = root.reveal && root.source ? root.source.password : "●".repeat(root.filled);

		return text.slice(Math.max(0, text.length - root.fieldWidth));
	}

	color: Config.surface

	function blockRows(text) {
		const lines = ["", "", "", "", ""];
		let first = true;

		for (let i = 0; i < text.length; i++) {
			const glyph = Config.lockDigits.find(entry => entry[0] === text[i]);

			if (!glyph)
				continue;

			for (let r = 0; r < 5; r++)
				lines[r] += (first ? "" : "  ") + glyph[r + 1].replace(/#/g, "██").replace(/ /g, "  ");

			first = false;
		}

		return lines;
	}

	function centerCol(length) {
		return Math.floor((root.cols - length) / 2);
	}

	function activate(index) {
		if (index === 1)
			root.revealPicked(!root.reveal);
		else if (root.switchable && index === root.switchSlot)
			root.choiceOpen = !root.choiceOpen;
		else if (index >= 2)
			Quickshell.execDetached(root.actions[index - 2].command);
	}

	FontMetrics {
		id: cell

		font.family: Config.fontFamily
		font.pixelSize: root.fontPixels
	}

	Timer {
		interval: 530
		running: true
		repeat: true
		onTriggered: root.blink = !root.blink
	}

	Timer {
		interval: 250
		repeat: true
		running: root.source !== null && !surface.activeFocus
		onTriggered: surface.forceActiveFocus()
	}

	SystemClock {
		id: stamp

		precision: Config.lockClockFormat.indexOf("s") >= 0 ? SystemClock.Seconds : SystemClock.Minutes
	}

	component Cell: Rectangle {
		id: slot

		property int col
		property int row
		property int span: 1
		property string glyph
		property int slotIndex
		property color ink: Config.foreground

		property bool lit: root.focusIndex === slot.slotIndex || hit.containsMouse

		x: slot.col * root.cellWidth
		y: slot.row * root.cellHeight
		width: slot.span * root.cellWidth
		height: root.cellHeight
		color: slot.lit ? Config.foreground : Config.surface

		Glyph {
			anchors.centerIn: parent
			width: root.cellWidth
			height: root.cellHeight
			size: root.fontPixels
			glyph: slot.glyph
			color: slot.lit ? Config.surface : slot.ink
		}

		MouseArea {
			id: hit

			anchors.fill: parent
			hoverEnabled: true
			onClicked: root.activate(slot.slotIndex)
		}
	}

	Item {
		id: surface

		anchors.fill: parent
		focus: true

		Component.onCompleted: surface.forceActiveFocus()

		MouseArea {
			anchors.fill: parent
			onPressed: surface.forceActiveFocus()
		}

		Repeater {
			model: 5

			Repeater {
				id: line

				required property int index

				readonly property string bits: root.clockRows[line.index] || ""
				readonly property int start: root.centerCol(line.bits.length)

				model: line.bits.length

				Rectangle {
					required property int index

					visible: line.bits[index] === "█"
					x: (line.start + index) * root.cellWidth
					y: (root.topRow + line.index) * root.cellHeight
					width: Math.ceil(root.cellWidth)
					height: root.cellHeight
					color: Config.foreground
				}
			}
		}

		Rectangle {
			x: (root.boxCol + 0.5) * root.cellWidth
			y: (root.topRow + 6.5) * root.cellHeight
			width: (root.boxWidth - 1) * root.cellWidth
			height: 2 * root.cellHeight
			radius: 0
			color: "transparent"
			border.width: 1
			border.color: root.message !== "" ? Config.red : root.mode === "checking" ? Config.dim : root.focusIndex === 0 ? Config.foreground : Config.dim
		}

		Glyph {
			x: (root.boxCol + 2) * root.cellWidth
			y: (root.topRow + 7) * root.cellHeight
			width: root.cellWidth
			height: root.cellHeight
			size: root.fontPixels
			glyph: Config.iconLock
			color: root.mode === "checking" ? Config.dim : Config.foreground
		}

		Text {
			x: (root.boxCol + 4) * root.cellWidth
			y: (root.topRow + 7) * root.cellHeight
			width: root.fieldWidth * root.cellWidth
			height: root.cellHeight
			horizontalAlignment: Text.AlignHCenter
			verticalAlignment: Text.AlignVCenter
			clip: true
			font: cell.font
			color: root.mode === "checking" ? Config.dim : Config.foreground
			text: root.field
		}

		Rectangle {
			visible: root.focusIndex === 0 && root.blink && root.mode !== "checking" && root.mode !== "open"
			x: (root.boxCol + 4 + root.fieldOffset + root.field.length) * root.cellWidth
			y: (root.topRow + 7) * root.cellHeight
			width: Math.ceil(root.cellWidth)
			height: root.cellHeight
			color: Config.foreground
		}

		Cell {
			col: root.boxCol + root.boxWidth - 4
			row: root.topRow + 7
			span: 3
			slotIndex: 1
			glyph: root.reveal ? Config.iconEyeOff : Config.iconEye
		}

		Text {
			readonly property string line: root.message.slice(0, root.cols)

			x: root.centerCol(line.length) * root.cellWidth
			y: (root.topRow + 10) * root.cellHeight
			width: line.length * root.cellWidth
			height: root.cellHeight
			visible: line.length > 0 && !root.choiceOpen
			verticalAlignment: Text.AlignVCenter
			elide: Text.ElideRight
			font: cell.font
			color: Config.red
			text: line
		}

		Repeater {
			model: root.slotCount - 2

			Cell {
				required property int index

				col: root.powerCol + index * 4
				row: root.powerRow
				span: 3
				slotIndex: index + 2
				glyph: index < root.actions.length ? root.actions[index].glyph : Config.iconUser
			}
		}

		Rectangle {
			visible: root.choiceOpen
			anchors.fill: parent
			color: Config.surface
			opacity: 0.85

			MouseArea {
				anchors.fill: parent
				onClicked: root.choiceOpen = false
			}
		}

		Rectangle {
			visible: root.choiceOpen
			x: root.panelCol * root.cellWidth
			y: root.panelRow * root.cellHeight
			width: root.panelWidth * root.cellWidth
			height: 5 * root.cellHeight
			color: Config.surface
			border.width: 1
			border.color: Config.dim
		}

		Repeater {
			model: root.choiceOpen ? 2 : 0

			Item {
				id: choice

				required property int index

				readonly property bool picked: root.choiceRow === choice.index
				readonly property color ink: choice.picked ? Config.foreground : Config.dim
				readonly property string name: root.source ? root.source.choiceName(choice.index) : ""

				x: root.panelCol * root.cellWidth
				y: (root.panelRow + 1 + choice.index * 2) * root.cellHeight
				width: root.panelWidth * root.cellWidth
				height: root.cellHeight

				Glyph {
					x: 2 * root.cellWidth
					width: root.cellWidth
					height: root.cellHeight
					size: root.fontPixels
					glyph: Config.iconChevron
					color: choice.ink
				}

				Text {
					x: 4 * root.cellWidth
					width: (root.panelWidth - 8) * root.cellWidth
					height: root.cellHeight
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					elide: Text.ElideRight
					font: cell.font
					color: choice.ink
					text: choice.name
				}

				Glyph {
					x: (root.panelWidth - 3) * root.cellWidth
					width: root.cellWidth
					height: root.cellHeight
					size: root.fontPixels
					glyph: Config.iconRight
					color: choice.ink
				}

				MouseArea {
					anchors.fill: parent
					hoverEnabled: true
					onEntered: root.choiceRow = choice.index
					onClicked: function (mouse) {
						root.source.step(choice.index, mouse.x < width / 2 ? -1 : 1);
					}
				}
			}
		}

		Keys.onPressed: function (event) {
			if (root.source === null)
				return;

			if (root.choiceOpen) {
				if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || event.key === Qt.Key_Down)
					root.choiceRow = 1 - root.choiceRow;
				else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right)
					root.source.step(root.choiceRow, event.key === Qt.Key_Left ? -1 : 1);
				else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Escape)
					root.choiceOpen = false;
				event.accepted = true;
				return;
			}

			if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
				root.focusPicked((root.focusIndex + (event.key === Qt.Key_Backtab ? root.slotCount - 1 : 1)) % root.slotCount);
				event.accepted = true;
				return;
			}

			if (root.focusIndex > 0 && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
				root.focusPicked(Math.max(1, Math.min(root.slotCount - 1, root.focusIndex + (event.key === Qt.Key_Left ? -1 : 1))));
				event.accepted = true;
				return;
			}

			if (event.key === Qt.Key_Escape) {
				if (root.focusIndex > 0)
					root.focusPicked(0);
				else
					root.source.dismiss();
				event.accepted = true;
				return;
			}

			if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
				if (root.focusIndex > 0)
					root.activate(root.focusIndex);
				else
					root.source.submit();
				event.accepted = true;
				return;
			}

			if (event.key === Qt.Key_Backspace) {
				root.focusPicked(0);
				root.source.back();
				event.accepted = true;
				return;
			}

			if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
				return;

			if (event.text.length > 0 && event.text.charCodeAt(0) >= 0x20) {
				root.focusPicked(0);
				root.source.type(event.text);
				event.accepted = true;
			}
		}
	}
}
