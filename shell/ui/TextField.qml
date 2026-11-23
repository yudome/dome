import QtQuick
import qs

Rectangle {
	id: root

	property string text: ""
	property string placeholder: ""
	property bool numeric: false
	property bool boxed: true
	property var accept: null
	property string label: ""

	readonly property bool editing: input.activeFocus

	signal committed(string text)

	implicitWidth: Config.appControlWidth
	implicitHeight: Config.appChipHeight
	radius: Config.appControlRadius
	color: root.boxed || input.activeFocus || hit.containsMouse ? Config.surfaceHover : "transparent"
	border.width: input.activeFocus ? Config.popupBorderWidth : 0
	border.color: Config.rule
	opacity: root.enabled ? 1 : Config.disabledOpacity

	function revert() {
		input.text = root.text;
	}

	function focusInput() {
		input.forceActiveFocus();
	}

	onTextChanged: if (!input.activeFocus) input.text = root.text

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.IBeamCursor
		onClicked: input.forceActiveFocus()
	}

	TextInput {
		id: input

		anchors.fill: parent
		anchors.leftMargin: Config.appControlRadius
		anchors.rightMargin: Config.appControlRadius
		verticalAlignment: TextInput.AlignVCenter
		horizontalAlignment: root.numeric ? TextInput.AlignRight : TextInput.AlignLeft
		clip: true
		selectByMouse: true
		activeFocusOnTab: true
		autoScroll: input.activeFocus
		font.family: Config.fontFamily
		font.pixelSize: Config.fontSize
		font.features: root.numeric ? ({ "tnum": 1 }) : ({})
		color: Config.foreground
		selectionColor: Config.surfaceHover
		text: root.text

		Accessible.role: Accessible.EditableText
		Accessible.name: root.label !== "" ? root.label : root.placeholder

		Keys.onEscapePressed: {
			root.revert();
			input.focus = false;
		}

		onEditingFinished: {
			if (input.text === root.text)
				return;
			if (root.accept && !root.accept(input.text)) {
				root.revert();
				return;
			}
			root.committed(input.text);
		}

		Label {
			anchors.fill: parent
			visible: input.text === "" && !input.activeFocus
			ink: Config.muted
			horizontalAlignment: input.horizontalAlignment
			verticalAlignment: Text.AlignVCenter
			text: root.placeholder
		}
	}
}
