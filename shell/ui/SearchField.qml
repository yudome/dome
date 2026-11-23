import QtQuick
import qs

Rectangle {
	id: root

	property alias text: input.text
	property string glyph: Config.launcherPrompt
	property string placeholder: ""
	property alias candidate: input.candidate
	property int echoMode: TextInput.Normal
	property bool typing: false
	property color boxColor: Config.surfaceRaised
	property real size: Config.launcherFontSize
	property real glyphSize: Math.round(root.size * 1.25)
	property real glyphSlot: 0
	property real gap: Math.round(root.size * 0.625)
	property real padding: Config.procSearchPadding
	property real boxHeight: 0
	property real corner: Config.rowRadius
	property real textOffset: 0

	signal accepted()
	signal edited()
	signal keyPressed(var event)

	readonly property real slot: root.slotWidth
	readonly property real slotWidth: root.glyphSlot > 0 ? root.glyphSlot : (root.glyph === "" ? 0 : root.glyphSize)
	readonly property real lineHeight: Math.round(root.size * 1.6)

	implicitWidth: 2 * root.padding + root.slot + root.gap + Config.procSearchMinWidth
	implicitHeight: root.boxHeight > 0 ? root.boxHeight : root.lineHeight + 2 * root.padding
	color: root.boxColor
	radius: root.corner

	function focusInput() {
		input.focusInput();
	}

	function startTyping() {
		root.typing = true;
	}

	function clear() {
		input.text = "";
	}

	onTypingChanged: {
		if (root.typing)
			root.focusInput();
	}

	Glyph {
		id: icon

		anchors.left: parent.left
		anchors.leftMargin: root.padding
		anchors.verticalCenter: parent.verticalCenter

		width: root.slotWidth
		height: root.glyphSize
		size: root.glyphSize
		color: Config.foreground
		glyph: root.glyph
	}

	InlineEdit {
		id: input

		anchors.left: icon.right
		anchors.right: parent.right
		anchors.leftMargin: root.gap
		anchors.rightMargin: root.padding
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: root.textOffset

		height: implicitHeight
		editing: root.typing
		echoMode: root.echoMode
		font.family: Config.fontFamily
		font.pixelSize: root.size

		onAccepted: root.accepted()
		onEdited: root.edited()
		onGhostCompleted: root.edited()
		onCancelled: root.typing = false
		onKeyPressed: function (event) { root.keyPressed(event); }
	}

	Text {
		anchors.left: input.left
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: root.textOffset

		visible: input.text === "" && root.placeholder !== ""
		font.family: Config.fontFamily
		font.pixelSize: root.size
		color: Config.muted
		text: root.placeholder
	}

	MouseArea {
		anchors.fill: parent

		onClicked: root.startTyping()
	}
}
