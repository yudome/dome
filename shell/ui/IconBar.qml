import QtQuick
import qs

Row {
	id: root

	property real size: Config.iconSize

	spacing: Config.gapsIn
	height: Math.max(root.size, root.childrenRect.height)
}
