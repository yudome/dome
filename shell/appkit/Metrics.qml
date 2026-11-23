pragma Singleton

import QtQuick
import qs

QtObject {
	readonly property real headerHeight: Config.appHeaderHeight
	readonly property real rowHeight: Config.appRowHeight
	readonly property real sidebarWidth: Config.appSidebarWidth
	readonly property real sidebarWideWidth: Config.appSidebarWideWidth
	readonly property real sidebarMin: Config.appSidebarMin
	readonly property real sidebarMax: Config.appSidebarMax
	readonly property real padding: Config.appPadding
	readonly property real paddingCompact: Config.appPaddingCompact
	readonly property real paddingWide: Config.appPaddingWide
	readonly property real column: Config.appColumn
	readonly property real gap: Config.appGap
	readonly property real gapSmall: Config.gapsIn
	readonly property real sectionGap: Config.appSectionGap
	readonly property real radius: Config.appRadius
	readonly property real controlRadius: Config.appControlRadius
	readonly property real controlWidth: Config.appControlWidth
	readonly property real chipHeight: Config.appChipHeight
	readonly property real titleSize: Config.appTitleSize
	readonly property real headingSize: Config.appHeadingSize
	readonly property real bodySize: Config.fontSize
	readonly property real captionSize: Config.appCaptionSize
	readonly property real iconSize: Config.iconSize
	readonly property real border: Config.popupBorderWidth
	readonly property real scrollbar: Config.scrollbarHoverWidth
	readonly property real compactWidth: Config.appCompactWidth
	readonly property real wideWidth: Config.appWideWidth
	readonly property real leading: Config.appChipHeight
	readonly property real disabled: Config.disabledOpacity

	function sizeClass(width) {
		return width < Config.appCompactWidth ? "compact" : width > Config.appWideWidth ? "wide" : "regular";
	}

	function paddingFor(sizeClass) {
		return sizeClass === "compact" ? Config.appPaddingCompact : sizeClass === "wide" ? Config.appPaddingWide : Config.appPadding;
	}
}
