import QtQuick
import qs

MenuList {
	id: root

	property Item anchor: null

	width: root.implicitWidth
	height: root.implicitHeight
	visible: false

	function place() {
		if (!root.anchor || !root.parent)
			return;

		const point = root.anchor.mapToItem(root.parent, 0, 0);
		root.x = Math.max(0, Math.min(root.parent.width - root.width, point.x + root.anchor.width - root.width));
		const below = point.y + root.anchor.height + Config.gapsIn;
		root.y = below + root.height <= root.parent.height ? below : Math.max(0, point.y - root.height - Config.gapsIn);
	}

	onVisibleChanged: if (visible) root.place()
	onAnchorChanged: if (visible) root.place()
	onHeightChanged: if (visible) root.place()
}
