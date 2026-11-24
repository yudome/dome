import QtQuick
import qs

Item {
	id: root

	property var levels: []
	property bool flip: false
	property color ink: Config.foreground

	readonly property real pitch: root.height / 4
	readonly property real dot: Math.max(1, Math.round(root.pitch * 0.6))

	Repeater {
		model: root.levels

		delegate: Item {
			id: column

			required property int index
			required property int modelData

			x: column.index * root.pitch
			width: root.pitch
			height: root.height

			Repeater {
				model: column.modelData

				delegate: Rectangle {
					required property int index

					x: Math.round((root.pitch - root.dot) / 2)
					y: Math.round((root.flip ? 3 - index : index) * root.pitch + (root.pitch - root.dot) / 2)
					width: root.dot
					height: root.dot
					antialiasing: false
					color: root.ink
				}
			}
		}
	}
}
