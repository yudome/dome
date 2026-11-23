pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit

AppWindow {
	id: win

	property bool mono: true
	property string forced: "auto"
	property string section: "Icons"

	readonly property string sizeClass: win.forced === "auto" ? Metrics.sizeClass(win.width) : win.forced
	readonly property var sections: [
		{ name: "Icons", glyph: "star" },
		{ name: "Text", glyph: "panels" },
		{ name: "Buttons", glyph: "puzzle" },
		{ name: "Inputs", glyph: "settings" },
		{ name: "Rows", glyph: "bar" },
		{ name: "Navigation", glyph: "right" },
		{ name: "Feedback", glyph: "bell" },
		{ name: "States", glyph: "refresh" }
	]

	appTitle: "Kit gallery"
	preset: "large"

	Binding {
		target: Config
		property: "overlay"
		value: ({ mono: win.mono })
	}

	AppAction {
		id: primaryAction

		text: "Primary"
		kind: "primary"
		onTriggered: demoTask.start(4)
	}

	AppAction {
		id: destroyAction

		text: "Destroy"
		icon: "close"
		kind: "danger"
		confirm: true
	}

	AppAction {
		id: dismissAction

		text: "Dismiss"
		kind: "ghost"
		onTriggered: demoTask.reset()
	}

	AppTask {
		id: demoTask
	}

	Timer {
		interval: Motion.slideMs
		repeat: true
		running: demoTask.running
		onTriggered: demoTask.step("Item " + (demoTask.done + 1), demoTask.done !== 2)
	}

	AppScaffold {
		id: scaffold

		anchors.fill: parent
		sizeClass: win.sizeClass

		sidebar: AppSidebar {
			searchable: true

			AppNav {
				model: win.sections
				current: win.section
				onPicked: function (name) {
					win.section = name;
					gallery.reveal(name);
					scaffold.closeDrawer();
				}
			}
		}

		header: AppHeader {
			title: "Kit"
			back: true
			sizeClass: win.sizeClass
			actions: [primaryAction, destroyAction]

			PillSwitch {
				anchors.verticalCenter: parent.verticalCenter
				model: [{ label: "Auto", value: "auto" }, { label: "S", value: "compact" }, { label: "M", value: "regular" }, { label: "L", value: "wide" }]
				selected: ["auto", "compact", "regular", "wide"].indexOf(win.forced)
				onPick: function (value) { win.forced = value; }
			}

			Switch {
				anchors.verticalCenter: parent.verticalCenter
				label: "Mono"
				checked: win.mono
				onToggled: function (checked) { win.mono = checked; }
			}
		}

		footer: AppFooter {
			shown: demoTask.total > 0
			task: demoTask
			text: demoTask.running ? demoTask.label : demoTask.failed > 0 ? demoTask.failed + " failed" : "Done"
			tone: demoTask.failed > 0 ? "warning" : "plain"
			actions: [dismissAction]
		}

		KitGallery {
			id: gallery

			anchors.fill: parent
			sizeClass: win.sizeClass
		}
	}
}
