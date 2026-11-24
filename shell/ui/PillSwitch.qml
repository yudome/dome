import QtQuick
import qs

Item {
	id: root

	property var model: []
	property int selected: 0
	property color ink: Config.foreground
	property color track: Config.toggleTrack
	property color hoverInk: Config.toggleHover
	property color labelInk: Config.toggleLabelInk
	property color fadedInk: Config.toggleFaded
	property var onPick

	readonly property int count: root.model.length
	readonly property int ready: slots.count
	readonly property real knobSize: Math.max(0, root.height - Config.togglePadding * 2)
	readonly property var active: root.selected >= 0 && root.selected < root.count && root.ready > root.selected ? slots.itemAt(root.selected) : null

	implicitHeight: Config.toggleHeight
	implicitWidth: row.implicitWidth + Config.togglePadding * 2

	function labelOf(entry) {
		if (entry === null || entry === undefined)
			return Config.toggleEmpty;

		if (typeof entry === "object")
			return entry.label !== undefined ? String(entry.label) : Config.toggleEmpty;

		return String(entry);
	}

	function isGlyph(text) {
		return text.length > 0 && text.length <= 2 && text.codePointAt(0) >= 0xe000;
	}

	function valueOf(entry) {
		return entry !== null && entry !== undefined && entry.value !== undefined ? entry.value : entry;
	}

	function pick(entry) {
		if (root.onPick)
			root.onPick(root.valueOf(entry));
	}

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: root.track
	}

	Rectangle {
		id: knob

		x: root.active ? Config.togglePadding + root.active.x : Config.togglePadding
		y: Config.togglePadding
		width: root.active ? root.active.width : root.knobSize
		height: root.knobSize
		radius: height / 2
		color: root.ink

		Behavior on x {
			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}

		Behavior on width {
			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}
	}

	Row {
		id: row

		x: Config.togglePadding
		height: parent.height

		Repeater {
			id: slots

			model: root.model

			delegate: Item {
				id: slot

				required property var modelData
				required property int index

				readonly property string text: root.labelOf(slot.modelData)
				readonly property bool glyph: root.isGlyph(slot.text)
				readonly property color tone: slot.index === root.selected ? root.labelInk : (hover.containsMouse ? root.ink : root.fadedInk)

				width: slot.glyph ? root.knobSize : word.implicitWidth + Config.toggleLabelPad * 2
				height: row.height

				Rectangle {
					x: 0
					y: Config.togglePadding
					width: parent.width
					height: root.knobSize
					radius: height / 2
					color: root.hoverInk
					opacity: hover.containsMouse && slot.index !== root.selected ? 1 : 0

					Behavior on opacity {
						NumberAnimation {
							duration: Config.toggleMs
						}
					}
				}

				Glyph {
					anchors.fill: parent
					visible: slot.glyph
					size: Config.toggleFontSize
					color: slot.tone
					glyph: slot.glyph ? slot.text : ""
				}

				Text {
					id: word

					anchors.centerIn: parent
					visible: !slot.glyph
					font.family: Config.fontFamily
					font.pixelSize: Config.toggleFontSize - 1
					color: slot.tone
					text: slot.glyph ? "" : slot.text
				}

				MouseArea {
					id: hover

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor

					onClicked: root.pick(slot.modelData)
				}
			}
		}
	}
}
