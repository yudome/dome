pragma ComponentBehavior: Bound

import QtQuick
import qs.appkit

AppSection {
	id: root

	required property var section
	required property var store

	title: root.section.title

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
