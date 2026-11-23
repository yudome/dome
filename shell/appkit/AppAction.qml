import QtQuick

QtObject {
	id: root

	property string text: ""
	property string icon: ""
	property string kind: "secondary"
	property bool enabled: true
	property bool busy: false
	property bool confirm: false

	signal triggered()

	function run() {
		if (root.enabled && !root.busy)
			root.triggered();
	}
}
