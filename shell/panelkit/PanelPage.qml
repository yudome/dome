import QtQuick
import qs

Item {
	id: root

	property real contentWidth: Config.cpuTooltipWidth
	property real contentHeight: body.childrenRect.y + body.childrenRect.height
	property real padding: Config.cpuTooltipPadding

	default property alias content: body.data

	signal closeRequested()

	focus: true
	implicitWidth: root.contentWidth + root.padding * 2
	implicitHeight: root.contentHeight + root.padding * 2

	Item {
		id: body

		x: root.padding
		y: root.padding
		width: root.contentWidth
		height: root.contentHeight
	}
}
