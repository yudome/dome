import QtQuick
import QtQuick.Dialogs
import qs

Item {
	id: root

	property string value: ""
	property string label: ""

	readonly property bool valid: /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(root.value)

	signal picked(string value)

	implicitWidth: Config.appControlWidth
	implicitHeight: Config.appChipHeight

	function hex(n) {
		return ("0" + Math.round(n * 255).toString(16)).slice(-2);
	}

	Rectangle {
		id: swatch

		anchors.right: field.left
		anchors.rightMargin: Config.gapsIn * 2
		anchors.verticalCenter: parent.verticalCenter
		width: Config.appChipHeight - Config.gapsIn * 2
		height: width
		radius: width / 2
		color: root.valid ? root.value : Config.surface
		border.width: Config.popupBorderWidth
		border.color: Config.rule
		activeFocusOnTab: true

		Accessible.role: Accessible.Button
		Accessible.name: root.label
		Accessible.onPressAction: dialog.open()

		Keys.onSpacePressed: dialog.open()
		Keys.onReturnPressed: dialog.open()

		FocusRing {
			radius: height / 2
		}

		MouseArea {
			anchors.fill: parent
			anchors.margins: -Config.gapsIn
			cursorShape: Qt.PointingHandCursor
			onClicked: dialog.open()
		}
	}

	TextField {
		id: field

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: Math.min(root.width - swatch.width - Config.gapsIn * 2, Config.appControlWidth / 2.5)
		boxed: false
		label: root.label
		text: root.value
		accept: function (text) { return /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(text); }
		onCommitted: function (text) { root.picked(text); }
	}

	ColorDialog {
		id: dialog

		selectedColor: root.valid ? root.value : Config.surface
		options: ColorDialog.ShowAlphaChannel
		onAccepted: {
			const c = dialog.selectedColor;
			root.picked(root.value.length === 9 ? "#" + root.hex(c.a) + root.hex(c.r) + root.hex(c.g) + root.hex(c.b) : "#" + root.hex(c.r) + root.hex(c.g) + root.hex(c.b));
		}
	}
}
