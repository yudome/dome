import QtQuick

Item {
	id: root

	property Item target: null
	property string edge: "bottom"
	property bool warned: false

	readonly property real line: {
		if (root.target === null || root.parent === null)
			return 0;

		if (root.target.inkTop === undefined) {
			if (!root.warned) {
				root.warned = true;
				console.warn("InkLine target has no ink metrics");
			}

			return 0;
		}

		const mid = (root.target.inkTop + root.target.inkBottom) / 2;
		const cap = root.target.capOffset === undefined ? mid : root.target.height / 2 - root.target.capOffset;
		const ink = root.edge === "top" ? root.target.inkTop : root.edge === "cap" ? cap : root.edge === "mid" ? mid : root.target.inkBottom;
		let item = root.target;
		let y = ink;

		while (item !== null && item !== root.parent) {
			y += item.y;
			item = item.parent;
		}

		return item === root.parent ? y : 0;
	}

	y: root.line
	width: 0
	height: 0
}
