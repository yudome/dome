import QtQuick
import qs

Row {
	id: root

	property string line: ""
	property string shortcut: root.line.indexOf(" ") > 0 ? root.line.slice(0, root.line.indexOf(" ")) : ""
	property string glyph: ""
	property string text: root.line.indexOf(" ") > 0 ? root.line.slice(root.line.indexOf(" ") + 1) : root.line
	property real size: Config.appCaptionSize
	property color ink: Config.foreground
	property color inkMuted: Config.muted
	property bool shown: true
	property real maxWidth: 0

	visible: Config.hints && root.shown && (root.shortcut !== "" || root.glyph !== "" || root.text !== "")
	spacing: Math.round(root.size * 0.4)

	readonly property real lead: (keyGlyph.visible ? keyGlyph.width + root.spacing : 0) + (keyLabel.visible ? keyLabel.implicitWidth + root.spacing : 0)

	Icon {
		id: keyGlyph

		anchors.verticalCenter: parent.verticalCenter
		visible: root.glyph !== ""
		width: root.size
		height: root.size
		size: root.size
		name: root.glyph
		ink: root.ink
	}

	Label {
		id: keyLabel

		anchors.verticalCenter: parent.verticalCenter
		visible: root.shortcut !== ""
		font.pixelSize: root.size
		ink: root.ink
		text: root.shortcut
	}

	Label {
		id: label

		anchors.verticalCenter: parent.verticalCenter
		width: root.maxWidth > 0 ? Math.min(implicitWidth, root.maxWidth - root.lead) : implicitWidth
		visible: root.text !== ""
		wrapMode: root.maxWidth > 0 ? Text.WordWrap : Text.NoWrap
		font.pixelSize: root.size
		ink: root.inkMuted
		text: root.text
	}
}
