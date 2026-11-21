import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.ui
import qs
import qs.services

PanelWindow {
	id: bar

	required property var modelData
	screen: modelData

	readonly property var layout: Yudae.bar && Yudae.bar.left ? Yudae.bar : barLayoutEmpty()
	readonly property alias widgets: body.widgets

	readonly property bool atBottom: bar.layout.position === "bottom"
	readonly property real outerMargin: Config.barFloating ? Config.gapsOut : 0
	readonly property var hyprMonitor: Hyprland.monitorFor(bar.screen)
	readonly property bool fullscreen: bar.hyprMonitor !== null && bar.hyprMonitor.activeWorkspace !== null && bar.hyprMonitor.activeWorkspace.hasFullscreen
	readonly property bool slideMode: Config.barFullscreenSlide === true
	readonly property real slideTarget: bar.slideMode ? -(bar.implicitHeight + bar.outerMargin) : 0
	property real slide: bar.fullscreen ? bar.slideTarget : 0
	property real contentFade: bar.fullscreen && !bar.slideMode ? 0 : 1
	readonly property bool slidAway: bar.fullscreen && (bar.slideMode ? bar.slide <= bar.slideTarget + 0.5 : bar.contentFade <= 0.01)
	property bool hidden: false
	visible: !bar.hidden || !bar.slideMode

	onSlidAwayChanged: if (bar.slidAway)
		bar.hidden = true

	onFullscreenChanged: {
		if (bar.fullscreen)
			bar.closePopups(null);
		else
			bar.hidden = false;
	}

	Behavior on slide {
		NumberAnimation {
			duration: Config.barSlideMs
			easing.type: Easing.BezierSpline
			easing.bezierCurve: [0.15, 0, 0.1, 1, 1, 1]
		}
	}

	Behavior on contentFade {
		NumberAnimation {
			duration: Config.barFadeMs
			easing.type: Easing.BezierSpline
			easing.bezierCurve: [0.15, 0, 0.1, 1, 1, 1]
		}
	}

	anchors {
		top: !bar.atBottom
		bottom: bar.atBottom
		left: true
		right: true
	}

	margins {
		top: bar.atBottom ? 0 : bar.outerMargin + bar.slide
		bottom: bar.atBottom ? bar.outerMargin + bar.slide : 0
		left: bar.outerMargin
		right: bar.outerMargin
	}

	implicitWidth: bar.screen ? bar.screen.width : 0
	implicitHeight: body.implicitHeight
	exclusiveZone: bar.implicitHeight
	color: "transparent"

	function isCenterSlot(id) {
		return body.isCenterSlot(id);
	}

	function closePopups(except) {
		Object.keys(bar.widgets).forEach(function (id) {
			const item = bar.widgets[id];

			if (item && item !== except && item.popupPersistent !== true && typeof item.closePopup === "function")
				item.closePopup();
		});
	}

	function anyPopupOpen() {
		return Object.keys(bar.widgets).some(function (id) {
			const item = bar.widgets[id];

			return item && typeof item.isPopupOpen === "function" && item.isPopupOpen();
		});
	}

	function openExclusive(widget, keyboard) {
		const open = widget && typeof widget.isPopupOpen === "function" && widget.isPopupOpen();

		if (widget && typeof widget.wantKeyboard === "function")
			widget.wantKeyboard(keyboard === true);

		if (open) {
			bar.closePopups(null);

			return;
		}

		bar.lastOpened = widget;

		if (widget && typeof widget.openPopup === "function")
			widget.openPopup();

		Handoff.run(function () {
			bar.closePopups(bar.lastOpened);
		});
	}

	property var lastOpened: null

	function toggleWidget(id, keyboard) {
		bar.openExclusive(bar.widgets[id], keyboard);
	}

	function toggleBare() {
		BarInk.toggle(bar);
	}

	Component.onCompleted: {
		BarInk.register(bar);

		if (BarInk.wantsBare)
			BarInk.ensure(bar);
	}

	Component.onDestruction: BarInk.unregister(bar)


	readonly property point origin: Qt.point(bar.margins.left, bar.atBottom
		? (bar.screen ? bar.screen.height : 0) - bar.margins.bottom - bar.implicitHeight
		: bar.margins.top)

	function widgetAt(x, y) {
		const ids = Object.keys(bar.widgets);

		for (let i = 0; i < ids.length; i++) {
			const item = bar.widgets[ids[i]];

			if (!item.visible)
				continue;

			const at = item.mapToItem(bar.contentItem, 0, 0);

			if (x - bar.origin.x >= at.x && x - bar.origin.x <= at.x + item.width && y - bar.origin.y >= at.y && y - bar.origin.y <= at.y + item.height)
				return item;
		}

		return null;
	}

	function clickAt(x, y) {
		const item = bar.widgetAt(x, y);

		if (item && typeof item.clicked === "function") {
			bar.closePopups(item);
			item.clicked();
			return;
		}

		bar.closePopups(null);
	}

	signal widgetActivated()

	function activateWidget(widget, keyboard) {
		const open = widget && typeof widget.isPopupOpen === "function" && widget.isPopupOpen();

		if (widget && typeof widget.wantKeyboard === "function")
			widget.wantKeyboard(keyboard === true);

		bar.closePopups(widget);

		if (!widget || typeof widget.openPopup !== "function")
			return;

		if (open) {
			widget.closePopup();
			return;
		}

		bar.widgetActivated();
		widget.openPopup();
	}

	BarBody {
		id: body

		anchors.fill: parent
		host: bar
		layout: bar.layout
		hidden: bar.hidden
		contentFade: bar.contentFade
		clear: BarInk.bare || (bar.fullscreen && !bar.slideMode)

		onBackgroundClicked: bar.closePopups(null)
		onBackgroundDoubleClicked: BarInk.toggle(bar)
	}

	function barLayoutEmpty() {
		return {
			position: "top",
			transparent: false,
			centerAnchor: "",
			left: [],
			center: [],
			right: []
		};
	}



}
