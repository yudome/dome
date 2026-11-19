import QtQuick
import qs

Item {
	id: root

	property alias text: input.text
	property alias cursorPosition: input.cursorPosition
	property alias echoMode: input.echoMode
	property alias horizontalAlignment: input.horizontalAlignment
	property alias verticalAlignment: input.verticalAlignment
	property alias selectByMouse: input.selectByMouse
	property alias font: input.font

	property string candidate: ""
	property var suggestions: []
	property bool editing: false
	property bool selectOnFocus: true
	property color color: Config.foreground
	property color selectionColor: Config.launcherHighlight
	property color selectedTextColor: Config.launcherHighlightText

	readonly property string ghost: root.text !== "" && root.candidate.length > root.text.length && root.candidate.toLowerCase().startsWith(root.text.toLowerCase()) ? root.candidate.slice(root.text.length) : ""
	readonly property bool hasGhost: root.ghost !== "" && input.activeFocus && input.cursorPosition === input.text.length && input.echoMode === TextInput.Normal
	readonly property bool hasSuggestions: root.suggestions.length > 0

	signal accepted()
	signal cancelled()
	signal edited()
	signal moved(int step)
	signal ghostCompleted()
	signal focusLost()
	signal keyPressed(var event)

	implicitWidth: input.implicitWidth
	implicitHeight: input.implicitHeight

	function focusInput() {
		input.forceActiveFocus();
	}

	function takeFocus() {
		if (!root.editing)
			return;

		root.focusInput();

		if (root.selectOnFocus)
			input.selectAll();
	}

	function scheduleFocus() {
		Qt.callLater(root.takeFocus);
	}

	function setText(value, select) {
		input.text = String(value === undefined || value === null ? "" : value);

		if (select)
			input.selectAll();
		else
			input.cursorPosition = input.text.length;
	}

	function completeGhost() {
		if (!root.hasGhost)
			return false;

		input.text = root.candidate;
		input.cursorPosition = input.text.length;
		root.ghostCompleted();
		return true;
	}

	onEditingChanged: {
		if (root.editing)
			root.scheduleFocus();
		else
			input.focus = false;
	}

	Component.onCompleted: if (root.editing) root.scheduleFocus()

	Text {
		visible: root.hasGhost && input.horizontalAlignment === TextInput.AlignLeft
		x: input.cursorRectangle.x
		y: input.cursorRectangle.y
		width: Math.max(0, root.width - x)
		height: input.cursorRectangle.height
		clip: true
		font: input.font
		verticalAlignment: Text.AlignVCenter
		color: Config.dim
		text: root.ghost
	}

	TextInput {
		id: input

		anchors.fill: parent
		clip: true
		color: root.color
		selectionColor: root.selectionColor
		selectedTextColor: root.selectedTextColor
		font.features: { "liga": 0, "calt": 0, "dlig": 0 }

		onAccepted: root.accepted()
		onTextEdited: root.edited()
		onActiveFocusChanged: {
			if (activeFocus) {
				if (root.selectOnFocus)
					input.selectAll();
			} else
				root.focusLost();
		}

		Keys.onPressed: function (event) {
			if (Input.cancel(event)) {
				root.cancelled();
				input.focus = false;
				event.accepted = true;
				return;
			}

			if (event.key === Qt.Key_Tab && root.completeGhost()) {
				event.accepted = true;
				return;
			}

			if (root.hasSuggestions && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
				root.moved(event.key === Qt.Key_Up ? -1 : 1);
				event.accepted = true;
				return;
			}

			root.keyPressed(event);
		}
	}
}
