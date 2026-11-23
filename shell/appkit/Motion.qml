pragma Singleton

import QtQuick
import qs

QtObject {
	readonly property int fadeMs: Config.popupFadeMs
	readonly property int slideMs: Config.popupSlideMs
	readonly property int toggleMs: Config.toggleMs
	readonly property int stepMs: Config.windowStepMs
	readonly property int scrollbarFadeMs: Config.scrollbarFadeMs
	readonly property int scrollbarIdleMs: Config.scrollbarIdleMs
	readonly property int tooltipDelayMs: Config.tooltipDelayMs
	readonly property int confirmMs: Config.confirmMs
	readonly property int easing: Easing.OutCubic
}
