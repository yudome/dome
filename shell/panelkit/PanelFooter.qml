import QtQuick
import qs
import qs.ui

Column {
	id: root

	default property alias content: row.data

	width: parent ? parent.width : 0
	spacing: Config.gapsIn * 2

	Separator {
		width: root.width
		color: Config.rule
	}

	Row {
		id: row

		anchors.right: parent.right
		spacing: Config.gapsIn * 2
	}
}
