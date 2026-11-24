import QtQuick
import qs
import qs.services

Item {
	id: root

	property bool dim: false
	property color dimColor: Config.foreground
	property string icon: ""
	property real iconSize: Config.iconSize
	property string inkId: ""
	property real iconLift: 0
	property var iconComponent: null
	property real iconWidth: 0
	property real iconMinWidth: 0
	property real iconHeight: 0
	property var bar: null
	readonly property bool onScreen: root.bar !== null && root.bar.visible && !root.bar.fullscreen
	property var onActivate
	property bool popupWanted: true
	property bool popupKeyboard: true
	property bool popupPersistent: false
	property bool popupPreload: false
	property bool popupSlide: false
	property bool popupAlignRight: false
	property bool popupCentered: false
	property bool popupAlwaysCentered: false
	property bool popupCenterScreen: false
	property real popupBorderWidth: -1
	property real popupPadding: -1
	property alias popupContent: popupWindow.contentSource

	readonly property alias popupVisible: popupWindow.shown

	function openPopup() {
		if (!root.popupWanted)
			return;

		popupWindow.open();
	}

	function closePopup() {
		popupWindow.close();
	}

	function isPopupOpen() {
		return popupWindow.shown;
	}

	function clicked() {
		if (root.onActivate)
			root.onActivate();
		else if (root.bar)
			root.bar.activateWidget(root, root.popupKeyboard);
	}

	readonly property real iconBreadth: root.iconComponent ? root.iconWidth : Math.max(iconMetrics.width, root.iconMinWidth)
	readonly property color inkColor: BarInk.pick(root.bar, root.inkId, root.dim ? root.dimColor : Config.foreground)
	readonly property real inkAbove: -iconsMetrics.tightBoundingRect.y
	readonly property real inkBelow: iconsMetrics.tightBoundingRect.y + iconsMetrics.tightBoundingRect.height
	readonly property real baselineLift: 0

	// The ink box of the icon font, measured from the baseline the glyphs sit
	// on. A drawn icon has no baseline of its own, so it is measured against
	// the glyphs it shares the bar with.
	readonly property real iconsInkAbove: -iconsMetrics.tightBoundingRect.y
	readonly property real iconsInkBelow: iconsMetrics.tightBoundingRect.y + iconsMetrics.tightBoundingRect.height

	// The height of the glyph ink, which is the height a drawn icon takes.
	readonly property real iconInkHeight: root.iconsInkAbove + root.iconsInkBelow

	// The line the icon glyphs sit on, in the content item's coordinates.
	readonly property real iconBaseline: root.inkAbove

	// The centre of the glyph ink, which is where an icon belongs, drawn or
	// not. A glyph is measured against its own ink, so a bigger glyph does not
	// sink below the line.
	readonly property real iconInkCentre: root.iconBaseline - root.iconsInkAbove + root.iconInkHeight / 2
	readonly property real glyphInkCentre: iconMetrics.tightBoundingRect.y + iconMetrics.tightBoundingRect.height / 2
	readonly property real glyphInkHeight: iconMetrics.tightBoundingRect.height

	implicitWidth: Math.ceil(root.iconBreadth)
	implicitHeight: Math.round(root.inkAbove + root.inkBelow)

	Tooltip {
		id: popupWindow

		anchorWindow: root.bar
		anchorItem: root
		contentPadding: root.popupPadding
		wantsKeyboard: root.popupKeyboard
		preload: root.popupPreload
		slideExit: root.popupSlide
		alignRight: root.popupAlignRight
		centered: root.popupCentered
		alwaysCentered: root.popupAlwaysCentered
		centerScreen: root.popupCenterScreen
		borderWidth: root.popupBorderWidth
	}

	TextMetrics {
		id: iconsMetrics
		font.family: Config.fontFamily
		font.pixelSize: root.iconSize
		text: Config.iconCpu + Config.iconMemory + Config.iconVolumeLow + Config.iconVolumeMid + Config.iconVolumeHigh + Config.iconBatteryFull + Config.iconBatteryHigh + Config.iconBatteryMid + Config.iconBatteryLow + Config.iconBatteryAlert + Config.iconBatteryCharge + Config.iconPowerPlug
	}

	TextMetrics {
		id: iconMetrics
		font.family: Config.fontFamily
		font.pixelSize: root.iconSize
		text: root.icon
	}

	MouseArea {
		anchors.fill: parent
		anchors.margins: -Config.barHitPadding

		onClicked: root.clicked()
	}

	Icon {
		id: labelIcon

		visible: root.iconComponent === null
		x: 0
		y: root.iconInkCentre - height / 2 - root.iconLift
		width: iconMetrics.advanceWidth
		height: root.iconSize
		size: root.iconSize
		glyph: root.icon
		ink: root.inkColor

		Behavior on ink {
			enabled: BarInk.fading
			ColorAnimation {
				duration: BarInk.fadeMs
			}
		}
	}

	Icon {
		id: iconSlot

		readonly property real drawnSize: root.iconHeight > 0 ? root.iconHeight : root.iconWidth
		readonly property real drawnWidth: root.iconHeight > 0 ? root.iconWidth : 0

		visible: root.iconComponent !== null
		x: 0
		y: root.iconInkCentre - iconSlot.drawnSize / 2 - root.iconLift
		width: iconSlot.drawnWidth > 0 ? iconSlot.drawnWidth : iconSlot.drawnSize
		height: iconSlot.drawnSize
		size: iconSlot.drawnSize
		ink: root.inkColor

		Loader {
			property color ink: iconSlot.ink

			anchors.fill: parent
			active: root.iconComponent !== null
			sourceComponent: root.iconComponent
		}
	}
}
