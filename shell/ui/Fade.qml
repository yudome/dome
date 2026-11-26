import QtQuick
import qs

Behavior {
	id: root

	property int duration: Config.popupFadeMs

	NumberAnimation {
		duration: root.duration
		easing.type: Easing.OutCubic
	}
}
