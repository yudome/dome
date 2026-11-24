import QtQuick
import qs

Column {
	id: root

	property string icon: ""
	property string source: ""
	property string text: ""
	property color ink: Config.muted
	property string hint: ""
	property string hintShortcut: ""

	spacing: Config.gapsIn * 2

	Icon {
		anchors.horizontalCenter: parent.horizontalCenter
		visible: root.icon !== "" || root.source !== ""
		width: Config.appTitleSize
		height: Config.appTitleSize
		size: Config.appTitleSize
		name: root.icon
		source: root.source
		ink: Config.dim
	}

	Label {
		anchors.horizontalCenter: parent.horizontalCenter
		width: Math.min(implicitWidth, root.parent ? root.parent.width : implicitWidth)
		horizontalAlignment: Text.AlignHCenter
		ink: root.ink
		text: root.text
	}

	Hint {
		anchors.horizontalCenter: parent.horizontalCenter
		shown: root.hint !== "" || root.hintShortcut !== ""
		shortcut: root.hintShortcut
		text: root.hint
		maxWidth: root.parent ? root.parent.width : 0
	}
}
