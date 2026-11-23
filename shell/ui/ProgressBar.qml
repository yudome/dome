import QtQuick
import qs
import qs.services

Item {
	id: root

	property var task: null
	property real value: root.task ? (root.task.total > 0 ? root.task.done / root.task.total : 0) : 0
	property color ink: root.task && root.task.failed > 0 ? Config.yellow : Config.foreground

	implicitWidth: Config.appControlWidth
	implicitHeight: Config.stepBarDot

	Accessible.role: Accessible.ProgressBar
	Accessible.name: root.task ? root.task.label || "" : ""

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: Config.dim
	}

	Rectangle {
		width: parent.width * Calc.clamp(root.value, 0, 1)
		height: parent.height
		radius: height / 2
		color: root.ink

		Behavior on width {
			NumberAnimation {
				duration: Config.toggleMs
				easing.type: Easing.OutCubic
			}
		}
	}
}
