pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import qs

Item {
	id: root

	property string name: ""
	property string glyph: ""
	property string source: ""
	property real size: Config.iconSize
	property color ink: Config.foreground
	property string align: "center"

	default property alias content: slot.data

	readonly property string resolved: root.glyph !== "" ? root.glyph : Config.glyph(root.name)
	readonly property bool custom: slot.children.length > 0 || root.source !== ""
	readonly property int status: image.item ? image.item.status : Image.Null
	readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
	readonly property real inkTop: glyphItem.inkTop
	readonly property real inkBottom: glyphItem.inkBottom
	readonly property real inkBelow: glyphItem.inkBelow

	implicitWidth: root.size
	implicitHeight: root.size

	Glyph {
		id: glyphItem

		anchors.fill: parent
		visible: !root.custom
		size: root.size
		color: root.ink
		onBaseline: root.align === "baseline"
		glyph: root.custom ? "" : root.resolved
	}

	Loader {
		id: image

		anchors.fill: parent
		active: root.source !== ""

		sourceComponent: IconImage {
			implicitSize: root.size
			source: root.source
			backer.sourceSize.width: root.size * root.dpr
			backer.sourceSize.height: root.size * root.dpr
		}
	}

	Item {
		id: slot

		anchors.fill: parent
	}
}
