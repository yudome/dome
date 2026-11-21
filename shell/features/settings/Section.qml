pragma ComponentBehavior: Bound

import QtQuick
import qs

Item {
	id: root

	required property var section
	required property var store
	property string title: root.section.title

	height: heading.height + 12 + panel.height

	Text {
		id: heading

		width: root.width
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsFontSize + 3
		color: Config.foreground
		text: root.title
	}

	Rectangle {
		id: panel

		y: heading.height + 12
		width: root.width
		height: list.height
		radius: Config.settingsRadius
		color: Config.settingsCard

		Column {
			id: list

			x: Config.settingsGap + 4
			width: parent.width - x * 2

			Repeater {
				model: root.section.keys

				delegate: Field {
					required property var modelData
					required property int index

					entry: modelData
					value: root.store.value(modelData.key, modelData.value)
					changed: root.store.pending[modelData.key] !== undefined
					last: index === root.section.keys.length - 1
					onSet: function (next) { root.store.setValue(modelData.key, next); }
				}
			}
		}
	}
}
