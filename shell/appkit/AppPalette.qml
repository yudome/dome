pragma Singleton

import QtQuick
import qs

QtObject {
	readonly property color surface: Config.surface
	readonly property color raised: Config.surfaceRaised
	readonly property color hover: Config.surfaceHover
	readonly property color rule: Config.rule
	readonly property color ink: Config.foreground
	readonly property color inkMuted: Config.muted
	readonly property color inkDim: Config.dim
	readonly property color inkOnInk: Config.surface
	readonly property color danger: Config.red
	readonly property color warning: Config.yellow
}
