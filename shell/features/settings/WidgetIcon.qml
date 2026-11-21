import QtQuick
import qs

Item {
	id: root

	property var source: null
	property real slot: 24

	width: root.slot
	height: root.slot
	clip: true

	Loader {
		id: loader

		active: root.visible
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		sourceComponent: root.source
		width: item ? Math.max(item.implicitWidth, 1) : 0
		height: item ? Math.max(item.implicitHeight, 1) : 0
	}
}
