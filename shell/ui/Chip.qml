import QtQuick
import qs

Item {
	id: root

	property string text: ""
	property string icon: ""
	property string glyph: ""
	property bool selected: false
	property bool ghost: false
	property bool hoverable: true
	property bool hot: false

	readonly property bool hovered: hit.containsMouse
	readonly property color ink: root.selected ? Config.surface : root.ghost ? Config.muted : Config.foreground

	signal clicked()

	implicitHeight: Config.appChipHeight
	implicitWidth: row.implicitWidth + Config.appGap * 1.5
	activeFocusOnTab: root.hoverable && root.enabled
	opacity: root.enabled ? 1 : Config.disabledOpacity

	Accessible.role: Accessible.Button
	Accessible.name: root.text
	Accessible.onPressAction: root.clicked()

	Keys.onSpacePressed: root.clicked()
	Keys.onReturnPressed: root.clicked()

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: root.selected ? Config.foreground : root.hot || hit.containsMouse && root.hoverable ? Config.toggleHover : Config.surfaceHover
		border.width: root.ghost ? Config.popupBorderWidth : 0
		border.color: Config.rule

		Behavior on color {
			ColorAnimation {
				duration: Config.toggleMs
			}
		}
	}

	Row {
		id: row

		anchors.centerIn: parent
		spacing: Config.gapsIn * 2

		Icon {
			anchors.verticalCenter: parent.verticalCenter
			visible: root.icon !== "" || root.glyph !== ""
			width: Config.appCaptionSize
			height: Config.appCaptionSize
			size: Config.appCaptionSize
			name: root.icon
			glyph: root.glyph
			ink: root.ink
		}

		Label {
			id: label

			anchors.verticalCenter: parent.verticalCenter
			anchors.verticalCenterOffset: label.capOffset
			visible: root.text !== ""
			role: "caption"
			ink: root.ink
			text: root.text
		}
	}

	FocusRing {
		radius: height / 2
	}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: root.hoverable
		enabled: root.hoverable && root.enabled
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}
}
