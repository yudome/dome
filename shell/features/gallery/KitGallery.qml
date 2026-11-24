pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit

AppPage {
	id: root

	property string status: "ready"
	property string draft: "Kit"
	property bool flag: true
	property string choice: "balanced"
	property string tab: "map"
	property real level: 0.4
	property var stop: 120
	property string swatch: Config.displayBase

	function reveal(name) {
		const item = sections.find(function (s) { return s.title === name; });
		if (item)
			root.flickable.contentY = Math.min(item.y, Math.max(0, root.flickable.contentHeight - root.flickable.height));
	}

	readonly property var sections: [iconSection, textSection, buttonSection, inputSection, rowSection, navSection, feedbackSection, stateSection]

	AppSection {
		id: iconSection

		title: "Icons"

		FormRow {
			width: parent.width
			label: "Icon"
			note: "Name, glyph, custom content"

			IconBar {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				size: Metrics.headingSize

				Icon {
					size: Metrics.headingSize
					name: "vm"
				}

				Icon {
					size: Metrics.headingSize
					name: "disk"
				}

				Icon {
					size: Metrics.headingSize
					name: "settings"
				}

				Icon {
					size: Metrics.headingSize

					Rectangle {
						anchors.fill: parent
						radius: width / 2
						color: AppPalette.ink
					}
				}
			}
		}

		FormRow {
			width: parent.width
			label: "IconButton"
			note: "Idle, selected, danger, disabled"
			last: true

			IconBar {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter

				IconButton {
					name: "refresh"
					label: "Refresh"
				}

				IconButton {
					name: "star"
					label: "Star"
					selected: true
				}

				IconButton {
					name: "close"
					label: "Close"
					danger: true
				}

				IconButton {
					name: "lock"
					label: "Lock"
					enabled: false
				}
			}
		}
	}

	AppSection {
		id: textSection

		title: "Text"

		Repeater {
			model: ["title", "heading", "body", "caption", "value"]

			delegate: FormRow {
				id: sample

				required property string modelData
				required property int index

				width: parent.width
				label: sample.modelData
				last: sample.index === 4

				Label {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width
					role: sample.modelData
					horizontalAlignment: Text.AlignRight
					text: sample.modelData === "value" ? "1234.56" : "Mono glyph type"
				}
			}
		}
	}

	AppSection {
		id: buttonSection

		title: "Buttons"

		Flow {
			width: parent.width
			spacing: Metrics.gapSmall * 2
			topPadding: Metrics.gap
			bottomPadding: Metrics.gap

			Button {
				kind: "primary"
				text: "Primary"
			}

			Button {
				text: "Secondary"
			}

			Button {
				kind: "ghost"
				text: "Ghost"
			}

			Button {
				kind: "danger"
				icon: "close"
				text: "Danger"
				confirm: true
			}

			Button {
				text: "Disabled"
				enabled: false
			}

			Button {
				text: "Busy"
				busy: true
			}

			Button {
				icon: "chevron"
			}

			Chip {
				icon: "cpu"
				text: "Chip"
			}

			Chip {
				text: "Selected"
				selected: true
			}

			Chip {
				text: "Ghost"
				ghost: true
			}
		}
	}

	AppSection {
		id: inputSection

		title: "Inputs"

		FormRow {
			width: parent.width
			label: "TextField"

			TextField {
				anchors.fill: parent
				text: root.draft
				onCommitted: function (value) { root.draft = value; }
			}
		}

		FormRow {
			width: parent.width
			label: "SearchField"

			SearchField {
				anchors.fill: parent
				boxColor: AppPalette.hover
				corner: Metrics.controlRadius
				padding: Metrics.gapSmall * 2
				glyph: Config.glyph("search")
				size: Metrics.bodySize
				glyphSize: Metrics.bodySize
				placeholder: "Search"
			}
		}

		FormRow {
			width: parent.width
			label: "Switch"
			pending: root.flag

			Switch {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				checked: root.flag
				onToggled: function (checked) { root.flag = checked; }
			}
		}

		FormRow {
			width: parent.width
			label: "PillSwitch"

			PillSwitch {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				model: ["saver", "balanced", "fast"]
				selected: ["saver", "balanced", "fast"].indexOf(root.choice)
				onPick: function (value) { root.choice = value; }
			}
		}

		FormRow {
			width: parent.width
			label: "Select"

			Select {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				options: ["saver", "balanced", "fast", "turbo", "silent"]
				value: root.choice
				onPicked: function (value) { root.choice = value; }
			}
		}

		FormRow {
			width: parent.width
			label: "ColorField"

			ColorField {
				anchors.fill: parent
				value: root.swatch
				onPicked: function (value) { root.swatch = value; }
			}
		}

		FormRow {
			width: parent.width
			label: "Slider"
			note: "SliderTrack"

			Slider {
				anchors.fill: parent
				from: 0
				to: 1
				stepSize: 0.05
				value: root.level
				onMoved: function (value) { root.level = value; }
			}
		}

		FormRow {
			width: parent.width
			label: "Slider"
			note: "GlyphScale"
			controlHeight: glyphSlider.implicitHeight
			last: true

			Slider {
				id: glyphSlider

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				stops: [60, 90, 120, 144, 165]
				value: root.stop
				onMoved: function (value) { root.stop = value; }

				renderer: Component {
					GlyphScale {
						animated: true
						glyph: function (c, r, n) { return r === 0 ? (c % 4 === 0 ? "|" : "'") : (c === n - 1 ? ">" : "="); }
					}
				}
			}
		}
	}

	AppSection {
		id: rowSection

		title: "Rows"

		ListRow {
			width: parent.width
			height: Metrics.rowHeight
			inset: 0
			hoverable: true
			rule: true
			icon: "vm"
			title: "ListRow"
			subtitle: "Leading, content, trailing"

			Badge {
				anchors.verticalCenter: parent.verticalCenter
				text: "hot"
			}

			Badge {
				anchors.verticalCenter: parent.verticalCenter
				text: "warning"
				tone: "warning"
			}
		}

		ListRow {
			width: parent.width
			height: Metrics.rowHeight
			inset: 0
			selected: true
			current: true
			icon: "check"
			title: "Selected and current"
		}

		Card {
			width: parent.width
			padding: Metrics.gap
			inset: Metrics.gap
			selected: true
			hoverable: true
			color: AppPalette.hover

			Label {
				width: parent.width
				text: "Card"
			}

			Label {
				width: parent.width
				role: "caption"
				text: "Selected and hoverable"
			}
		}

		Item {
			width: parent.width
			height: Metrics.gap
		}
	}

	AppSection {
		id: navSection

		title: "Navigation"

		FormRow {
			width: parent.width
			label: "NavItem"

			Row {
				anchors.fill: parent
				spacing: Metrics.gapSmall

				NavItem {
					width: parent.width / 2 - Metrics.gapSmall / 2
					icon: "disk"
					text: "Selected"
					selected: true
				}

				NavItem {
					width: parent.width / 2 - Metrics.gapSmall / 2
					icon: "vm"
					text: "Idle"
				}
			}
		}

		FormRow {
			width: parent.width
			label: "Tabs"

			Tabs {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				model: [{ label: "Map", value: "map" }, { label: "Packages", value: "packages" }, { label: "Caches", value: "caches" }]
				current: root.tab
				onPicked: function (value) { root.tab = value; }
			}
		}

		FormRow {
			width: parent.width
			label: "Breadcrumb"
			last: true

			Breadcrumb {
				anchors.fill: parent
				segments: [{ label: "/", value: "/" }, { label: "home", value: "/home" }, { label: "gabriel", value: "/home/gabriel" }, { label: "dotfiles", value: "/home/gabriel/dotfiles" }]
			}
		}
	}

	AppSection {
		id: feedbackSection

		title: "Feedback"

		FormRow {
			width: parent.width
			label: "Badge"

			IconBar {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter

				Badge {
					text: "plain"
				}

				Badge {
					text: "warning"
					tone: "warning"
				}

				Badge {
					text: "danger"
					tone: "danger"
				}
			}
		}

		FormRow {
			width: parent.width
			label: "ProgressBar"

			ProgressBar {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				value: root.level
			}
		}

		FormRow {
			width: parent.width
			label: "Hint"
			note: "Key and label, key glyph"

			IconBar {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				spacing: Metrics.gap

				Hint {
					line: Config.procSearchHint
				}

				Hint {
					shortcut: "Alt1"
				}

				Hint {
					glyph: "enter"
				}
			}
		}

		FormRow {
			width: parent.width
			label: "Braille"

			Braille {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
			}
		}

		FormRow {
			width: parent.width
			label: "MenuList"
			controlHeight: menu.implicitHeight
			last: true

			MenuList {
				id: menu

				anchors.right: parent.right
				width: Metrics.controlWidth * 0.75
				height: implicitHeight
				current: "wake"
				entries: [{ label: "Wake", icon: "sun", value: "wake" }, { label: "Stop", icon: "powerOff", enabled: false }, { label: "Destroy", confirmLabel: Config.vmDestroyConfirm, hint: Config.vmDestroyHint, icon: "close", danger: true, confirm: true }]
			}
		}
	}

	AppSection {
		id: stateSection

		title: "States"

		tools: PillSwitch {
			model: ["loading", "empty", "error", "ready"]
			selected: ["loading", "empty", "error", "ready"].indexOf(root.status)
			onPick: function (value) { root.status = value; }
		}

		StateView {
			width: parent.width
			height: Metrics.controlWidth / 2
			status: root.status
			icon: "search"
			emptyText: "No matches"
			onRetry: root.status = "ready"

			EmptyState {
				anchors.centerIn: parent
				icon: "check"
				text: "Ready"
			}
		}
	}
}
