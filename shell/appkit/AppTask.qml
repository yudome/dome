import QtQuick

QtObject {
	id: root

	property bool running: false
	property int done: 0
	property int total: 0
	property int failed: 0
	property string label: ""

	readonly property bool finished: !root.running && root.total > 0
	readonly property real progress: root.total > 0 ? root.done / root.total : 0

	function start(total) {
		root.total = total;
		root.done = 0;
		root.failed = 0;
		root.label = "";
		root.running = total > 0;
	}

	function step(label, ok) {
		root.done += 1;
		if (ok === false)
			root.failed += 1;
		root.label = label || "";
		if (root.done >= root.total)
			root.running = false;
	}

	function reset() {
		root.running = false;
		root.done = 0;
		root.total = 0;
		root.failed = 0;
		root.label = "";
	}
}
