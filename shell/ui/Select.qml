import QtQuick
import QtQuick.Controls as QQC
import qs

Item {
	id: root

	property var options: []
	property var value: undefined
	property string label: ""

	readonly property var entries: root.options.map(function (o) {
		return typeof o === "object" && o !== null ? o : { label: String(o).charAt(0).toUpperCase() + String(o).slice(1), value: o };
	})
	readonly property var chosen: root.entries.find(function (e) { return e.value === root.value; })

	signal picked(var value)

	implicitWidth: Config.appControlWidth / 2
	implicitHeight: Config.appChipHeight
	activeFocusOnTab: root.enabled
	opacity: root.enabled ? 1 : Config.disabledOpacity

	Accessible.role: Accessible.ComboBox
	Accessible.name: root.label
	Accessible.onPressAction: popup.open()

	Keys.onSpacePressed: popup.open()
	Keys.onReturnPressed: popup.open()

	Rectangle {
		anchors.fill: parent
		radius: Config.appControlRadius
		color: hit.containsMouse || popup.opened ? Config.toggleHover : Config.surfaceHover
	}

	Label {
		id: valueLabel

		anchors.left: parent.left
		anchors.leftMargin: Config.appControlRadius + Config.gapsIn
		anchors.right: chevron.left
		anchors.rightMargin: Config.gapsIn
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: valueLabel.capOffset
		text: root.chosen ? root.chosen.label : ""
	}

	Icon {
		id: chevron

		anchors.right: parent.right
		anchors.rightMargin: Config.appControlRadius
		anchors.verticalCenter: parent.verticalCenter
		width: Config.appCaptionSize
		height: Config.appCaptionSize
		size: Config.appCaptionSize
		name: "down"
		ink: Config.muted
	}

	FocusRing {}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: popup.opened ? popup.close() : popup.open()
	}

	QQC.Popup {
		id: popup

		y: root.height + Config.gapsIn
		width: Math.max(root.width, menu.implicitWidth)
		padding: 0
		focus: true
		background: null

		contentItem: MenuList {
			id: menu

			entries: root.entries
			current: root.value
			menuWidth: root.width
			onPicked: function (entry) {
				popup.close();
				if (entry.value !== root.value)
					root.picked(entry.value);
			}
		}
	}
}
