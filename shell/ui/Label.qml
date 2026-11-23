import QtQuick
import qs

Text {
	id: root

	property string role: "body"
	property color ink: root.role === "caption" ? Config.muted : Config.foreground

	readonly property real roleSize: root.role === "title" ? Config.appTitleSize : root.role === "heading" ? Config.appHeadingSize : root.role === "caption" ? Config.appCaptionSize : Config.fontSize
	readonly property real capOffset: (cap.ascent + cap.descent) / 2 - cap.ascent + capInk.tightBoundingRect.height / 2

	font.family: Config.fontFamily
	font.pixelSize: root.roleSize
	font.features: root.role === "value" ? ({ "tnum": 1 }) : ({})
	color: root.ink
	elide: Text.ElideRight
	horizontalAlignment: root.role === "value" ? Text.AlignRight : Text.AlignLeft

	FontMetrics {
		id: cap

		font: root.font
	}

	TextMetrics {
		id: capInk

		font: root.font
		text: "H"
	}
}
