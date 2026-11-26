import QtQuick
import qs

Item {
	id: root

	property bool shadowEnabled: true
	readonly property var settings: Config.hyprShadow
	readonly property bool active: root.shadowEnabled && root.settings.enabled && root.settings.range > 0
	readonly property color tint: Qt.color(root.qmlColor(root.settings.color))
	readonly property real range: root.settings.range || 0
	readonly property real offset: root.settings.offsetY || 0
	readonly property real contact: root.settings.contact || 0
	readonly property real strength: root.tint.a * (root.settings.alpha === undefined ? 1 : root.settings.alpha)
	readonly property real pad: root.range + Math.abs(root.offset) + 2
	property real topReach: -1
	property real bottomReach: -1
	property real scale: 1
	readonly property real clipTop: root.topReach >= 0 ? root.topReach : root.pad
	readonly property real clipBottom: root.bottomReach >= 0 ? root.bottomReach : root.pad
	readonly property real clipSide: root.pad

	function qmlColor(value) {
		const text = String(value || "");
		let match = text.match(/^rgba\(([0-9a-f]{8})\)$/i);

		if (match)
			return "#" + match[1].slice(6, 8) + match[1].slice(0, 6);

		match = text.match(/^rgb\(([0-9a-f]{6})\)$/i);

		if (match)
			return "#" + match[1];

		match = text.match(/^0x([0-9a-f]{8})$/i);

		return match ? "#" + match[1] : text || Config.surfaceTranslucent;
	}

	Item {
		x: -root.clipSide
		y: -root.clipTop
		width: root.width + 2 * root.clipSide
		height: root.height + root.clipTop + root.clipBottom
		clip: true
		visible: root.active

		NativeShadow {
			x: root.clipSide - root.pad
			y: root.clipTop - root.pad
			width: root.width + 2 * root.pad
			height: root.height + 2 * root.pad
			cardWidth: root.width
			cardHeight: root.height
			range: root.range
			offset: root.offset
			alpha: root.strength
			contact: root.contact
			radius: 0
			textureScale: root.scale
			tint: root.tint
		}
	}
}
