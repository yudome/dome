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

	property string ghost: ""
	property var suggestions: []
	property bool editing: false
	property bool selectOnFocus: true
	property color color: Config.foreground
	property color selectionColor: Config.launcherHighlight
	property color selectedTextColor: Config.launcherHighlightText

	readonly property bool hasGhost: root.ghost !== "" && root.text !== ""
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

		input.text = input.text + root.ghost;
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

	TextMetrics {
		id: measure

		font: input.font
		text: input.text
	}

	Text {
		id: ghostText

		visible: root.hasGhost && input.horizontalAlignment === TextInput.AlignLeft
		x: measure.width
		anchors.verticalCenter: parent.verticalCenter
		width: Math.max(0, root.width - x)
		height: root.height
		elide: Text.ElideRight
		font: input.font
		verticalAlignment: input.verticalAlignment
		color: Config.muted
		text: root.ghost
	}

	TextInput {
		id: input

		anchors.fill: parent
		clip: true
		color: root.color
		selectionColor: root.selectionColor
		selectedTextColor: root.selectedTextColor

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

			if (event.key === Qt.Key_Tab && root.hasGhost) {
				root.completeGhost();
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
