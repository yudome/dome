import QtQuick
import qs

Item {
	id: root

	property string title: ""
	property string subtitle: ""
	property string icon: ""
	property string glyph: ""
	property real iconSize: Config.fontSize
	property bool selected: false
	property bool current: false
	property bool dim: false
	property bool hoverable: false
	property bool rule: false
	property real inset: Config.rowInset
	property real leadingWidth: root.height - Config.rowInset * 2
	property Component leading: null

	default property alias trailing: tail.data

	readonly property bool hovered: hover.hovered
	readonly property bool hot: root.selected || (root.hoverable && hover.hovered)
	readonly property color ink: root.dim && !root.hot ? Config.muted : Config.foreground
	readonly property bool hasLeading: root.leading !== null || root.icon !== "" || root.glyph !== ""

	signal activated()

	implicitHeight: Config.rowHeight
	implicitWidth: Config.appControlWidth
	activeFocusOnTab: root.hoverable && root.enabled

	Accessible.role: Accessible.ListItem
	Accessible.name: root.title
	Accessible.onPressAction: root.activated()

	Keys.onSpacePressed: root.activated()
	Keys.onReturnPressed: root.activated()

	HoverHandler {
		id: hover

		enabled: root.hoverable
	}

	Rectangle {
		anchors.fill: parent
		radius: Config.appControlRadius
		color: root.selected ? Config.surfaceRaised : Config.surfaceHover
		opacity: root.hot ? 1 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: Config.toggleMs
			}
		}
	}

	Separator {
		visible: root.rule
		anchors.bottom: parent.bottom
		width: parent.width
		color: Config.rule
	}

	MouseArea {
		id: hit

		anchors.fill: parent
		hoverEnabled: root.hoverable
		cursorShape: root.hoverable ? Qt.PointingHandCursor : Qt.ArrowCursor
		onClicked: root.activated()
	}

	Row {
		id: lead

		anchors.left: parent.left
		anchors.leftMargin: root.inset
		anchors.verticalCenter: parent.verticalCenter
		spacing: Config.mixerListGap

		Loader {
			width: root.leadingWidth
			height: root.leadingWidth
			visible: root.leading !== null
			active: root.leading !== null
			sourceComponent: root.leading
		}

		Item {
			width: root.leadingWidth
			height: root.leadingWidth
			visible: root.icon !== "" || root.glyph !== ""

			Rectangle {
				anchors.fill: parent
				radius: width / 2
				color: Config.foreground
				visible: root.current
			}

			Icon {
				anchors.centerIn: parent
				width: root.iconSize
				height: root.iconSize
				size: root.iconSize
				name: root.icon
				glyph: root.glyph
				ink: root.current ? Config.surface : root.ink
			}
		}
	}

	Row {
		id: tail

		anchors.right: parent.right
		anchors.rightMargin: root.inset
		anchors.verticalCenter: parent.verticalCenter
		spacing: Config.mixerListGap
	}

	Column {
		anchors.left: lead.right
		anchors.leftMargin: root.hasLeading ? Config.mixerListGap : 0
		anchors.right: tail.left
		anchors.rightMargin: tail.children.length > 0 ? Config.mixerListGap : 0
		anchors.verticalCenter: parent.verticalCenter

		Label {
			id: titleLabel

			width: parent.width
			ink: root.ink
			text: root.title
		}

		Label {
			width: parent.width
			visible: root.subtitle !== ""
			role: "caption"
			text: root.subtitle
		}
	}

	FocusRing {}
}
