import QtQuick
import QtQuick.Controls as QQC
import qs

Item {
	id: root

	property string name: ""
	property string glyph: ""
	property string label: ""
	property real size: Config.iconSize
	property real box: Config.appChipHeight
	property bool selected: false
	property bool danger: false
	property bool reveal: false
	property bool shown: true
	property bool flat: false
	property real hitMargin: 0
	property color ink: root.danger ? Config.red : Config.foreground
	property color inkIdle: root.danger ? Config.red : Config.muted

	default property alias content: icon.content

	readonly property bool hovered: hit.containsMouse
	readonly property bool visibleNow: !root.reveal || root.shown || root.hovered || root.activeFocus

	signal clicked()

	implicitWidth: root.box
	implicitHeight: root.box
	opacity: !root.enabled ? Config.disabledOpacity : root.visibleNow ? 1 : 0
	activeFocusOnTab: root.enabled && root.visibleNow

	Accessible.role: Accessible.Button
	Accessible.name: root.label !== "" ? root.label : root.name
	Accessible.onPressAction: root.clicked()

	Keys.onSpacePressed: root.clicked()
	Keys.onReturnPressed: root.clicked()
	Keys.onEnterPressed: root.clicked()

	Behavior on opacity {
		NumberAnimation {
			duration: Config.popupFadeMs
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: Config.appControlRadius
		color: root.selected ? Config.surfaceRaised : Config.surfaceHover
		visible: !root.flat
		opacity: root.selected || hit.containsMouse ? 1 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: Config.toggleMs
			}
		}
	}

	Icon {
		id: icon

		anchors.centerIn: parent
		width: root.size
		height: root.size
		size: root.size
		name: root.name
		glyph: root.glyph
		ink: root.selected || hit.containsMouse ? root.ink : root.inkIdle
	}

	FocusRing {}

	MouseArea {
		id: hit

		anchors.fill: parent
		anchors.margins: -root.hitMargin
		hoverEnabled: true
		enabled: root.enabled && root.visibleNow
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}

	QQC.ToolTip {
		visible: root.label !== "" && hit.containsMouse
		delay: Config.tooltipDelayMs
		text: root.label
		font.family: Config.fontFamily
		font.pixelSize: Config.appCaptionSize

		contentItem: Label {
			role: "caption"
			ink: Config.foreground
			text: root.label
		}

		background: Rectangle {
			radius: Config.appControlRadius
			color: Config.surfaceRaised
			border.width: Config.popupBorderWidth
			border.color: Config.rule
		}
	}
}
