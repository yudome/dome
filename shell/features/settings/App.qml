pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.ui

AppWindow {
	id: win

	appTitle: "Settings"
	appMinWidth: 760
	appMinHeight: 520
	implicitWidth: 1180
	implicitHeight: 780

	property var schema: ({ apply: "instant", pages: [] })
	property string page: ""
	property var history: []
	property string query: ""
	property string widgetGroup: "All"
	property var layoutDoc: null
	property var pending: ({})
	property var pendingLayout: null
	property var expect: ({})
	property int writes: 0
	property var features: ({})
	property string failed: ""

	readonly property bool manual: win.schema.apply === "manual"
	readonly property var pages: win.schema.pages || []
	readonly property var current: win.pages.find(function (p) { return p.name === win.page; }) || win.pages[0] || ({ name: "", sections: [] })
	readonly property var layout: win.pendingLayout || win.layoutDoc
	readonly property bool dirty: Object.keys(win.pending).length > 0 || win.pendingLayout !== null
	readonly property bool barShown: win.manual && (win.dirty || win.failed !== "")
	readonly property bool searching: win.query.trim() !== ""
	readonly property var library: Object.keys(win.features).sort().map(function (id) { return win.features[id]; })
	readonly property var widgetGroups: [
		{ name: "All", sections: [] },
		{ name: "System", sections: ["cpu", "memory"] },
		{ name: "Sound", sections: ["mixer", "media"] },
		{ name: "Network", sections: ["network", "weather"] },
		{ name: "Time", sections: ["calendar", "contrib"] },
		{ name: "Agent", sections: ["agent"] },
		{ name: "Storage", sections: ["disk"] }
	]
	readonly property var pageSections: {
		const sections = win.current.sections || [];
		if (win.widgetGroup === "All")
			return sections;
		const group = win.widgetGroups.find(function (g) { return g.name === win.widgetGroup; });
		if (!group)
			return sections;
		return sections.filter(function (section) { return group.sections.indexOf(section.name) >= 0; });
	}
	readonly property var found: {
		const q = win.query.trim().toLowerCase();
		if (q === "")
			return [];
		const out = [];
		win.pages.forEach(function (p) {
			p.sections.forEach(function (s) {
				const whole = s.title.toLowerCase().indexOf(q) >= 0 || p.name.toLowerCase().indexOf(q) >= 0;
				const keys = whole ? s.keys : s.keys.filter(function (k) {
					return k.label.toLowerCase().indexOf(q) >= 0 || k.key.toLowerCase().indexOf(q) >= 0;
				});
				if (keys.length > 0)
					out.push({ name: s.name, title: s.title, keys: keys });
			});
		});
		return out;
	}

	Binding {
		target: Config
		property: "overlay"
		value: win.manual ? win.pending : ({})
	}

	function load() {
		Yudae.request("settings", "schema", {}, function (result) {
			if (result && result.pages)
				win.schema = win.withExpect(result);
			if (win.page === "" && win.pages.length > 0) {
				const wanted = (Quickshell.env("YUDAE_PANE") || "").toLowerCase();
				const hit = win.pages.find(function (p) { return p.name.toLowerCase() === wanted || p.name.toLowerCase().indexOf(wanted) === 0 && wanted !== ""; });
				win.page = hit ? hit.name : win.pages[0].name;
			}
		});
	}

	function go(name) {
		if (name === win.page && !win.searching)
			return;
		win.history = win.history.concat([win.page]);
		win.page = name;
		win.query = "";
		search.clear();
		flick.contentY = 0;
	}

	function back() {
		if (flick.contentY > 0) {
			flick.contentY = 0;
			return;
		}
		if (win.history.length === 0)
			return;
		win.page = win.history[win.history.length - 1];
		win.history = win.history.slice(0, -1);
	}

	function value(key, fallback) {
		return win.pending[key] !== undefined ? win.pending[key] : fallback;
	}

	function send(key, next) {
		win.writes += 1;
		Yudae.request("settings", "set", { key: key, value: next }, function (result) {
			win.failed = result === null ? key : "";
			win.writes = Math.max(0, win.writes - 1);
			win.load();
			if (win.writes === 0)
				win.expect = ({});
		});
	}

	function withExpect(next) {
		if (Object.keys(win.expect).length === 0)
			return next;
		const pages = next.pages.map(function (page) {
			return {
				name: page.name,
				glyph: page.glyph,
				sections: page.sections.map(function (section) {
					return {
						name: section.name,
						title: section.title,
						keys: section.keys.map(function (key) {
							return win.expect[key.key] === undefined ? key : Object.assign({}, key, { value: win.expect[key.key] });
						})
					};
				})
			};
		});
		return { apply: next.apply, pages: pages };
	}

	function original(key) {
		for (let p = 0; p < win.pages.length; p++) {
			const sections = win.pages[p].sections;
			for (let s = 0; s < sections.length; s++) {
				const keys = sections[s].keys;
				for (let k = 0; k < keys.length; k++) {
					if (keys[k].key === key)
						return keys[k].value;
				}
			}
		}
		return undefined;
	}

	function setValue(key, next) {
		const unchanged = next === win.original(key);
		if (!win.manual || key === "settingsApply") {
			if (!unchanged)
				win.send(key, next);
			return;
		}
		const out = Object.assign({}, win.pending);
		if (unchanged)
			delete out[key];
		else
			out[key] = next;
		win.pending = out;
	}

	function setLayout(next) {
		if (!win.manual) {
			win.layoutDoc = next;
			Yudae.request("bar", "layout", { layout: next }, function (result) {
				if (result === null)
					win.failed = "layout";
			});
			return;
		}
		win.pendingLayout = JSON.stringify(next) === JSON.stringify(win.layoutDoc) ? null : next;
	}

	function merged() {
		const pages = win.pages.map(function (page) {
			return {
				name: page.name,
				glyph: page.glyph,
				sections: page.sections.map(function (section) {
					return {
						name: section.name,
						title: section.title,
						keys: section.keys.map(function (key) {
							return win.pending[key.key] === undefined ? key : Object.assign({}, key, { value: win.pending[key.key] });
						})
					};
				})
			};
		});
		return { apply: win.schema.apply, pages: pages };
	}

	function apply() {
		win.failed = "";
		win.expect = Object.assign({}, win.expect, win.pending);
		win.schema = win.merged();
		Object.keys(win.pending).forEach(function (key) { win.send(key, win.pending[key]); });
		if (win.pendingLayout !== null) {
			const next = win.pendingLayout;
			win.layoutDoc = next;
			Yudae.request("bar", "layout", { layout: next }, function (result) {
				if (result === null)
					win.failed = "layout";
			});
		}
		win.pending = {};
		win.pendingLayout = null;
	}

	function revert() {
		win.pending = {};
		win.pendingLayout = null;
		win.expect = ({});
		win.failed = "";
	}

	Connections {
		target: Yudae

		function onConnectedChanged() {
			if (Yudae.connected)
				win.load();
		}

		function onSettingsChanged() {
			reloadTimer.restart();
		}
	}

	Timer {
		id: reloadTimer

		interval: 150
		onTriggered: win.load()
	}

	Component.onCompleted: if (Yudae.connected) win.load()

	FileView {
		path: Quickshell.shellDir + "/topbarlayout.json"
		watchChanges: true
		printErrors: false

		onFileChanged: this.reload()
		onLoaded: {
			try {
				win.layoutDoc = JSON.parse(this.text());
			} catch (error) {
				win.layoutDoc = { version: 1, bar: { layout: { left: [], center: [], right: [] } } };
			}
		}
	}

	FolderListModel {
		id: featureDirs

		folder: "file://" + Quickshell.shellDir + "/features"
		showDirs: true
		showFiles: false
	}

	Instantiator {
		model: featureDirs

		delegate: FileView {
			required property string filePath

			path: filePath + "/feature.json"
			printErrors: false

			onLoaded: {
				let info = null;
				try {
					info = JSON.parse(this.text());
				} catch (error) {
					return;
				}
				if (!info.widget || !info.name)
					return;
				const out = Object.assign({}, win.features);
				out[info.name] = { id: info.name, glyph: info.glyph || "", description: info.description || "" };
				win.features = out;
			}
		}
	}

	Rectangle {
		id: sidebar

		width: Config.settingsSidebarWidth
		height: parent.height
		color: Config.settingsSidebar

		Rectangle {
			anchors.right: parent.right
			width: 1
			height: parent.height
			color: Config.settingsRule
		}

		Rectangle {
			id: search

			x: 12
			y: 16
			width: parent.width - 24
			height: 34
			radius: 8
			color: Config.launcherSearchBox

			Glyph {
				id: searchGlyph

				x: 10
				anchors.verticalCenter: parent.verticalCenter
				width: 14
				height: 14
				size: Config.settingsFontSize
				color: Config.settingsLabel
				glyph: Config.glyph("search")
			}

			TextInput {
				id: searchInput

				anchors.left: searchGlyph.right
				anchors.leftMargin: 8
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				height: parent.height
				verticalAlignment: TextInput.AlignVCenter
				clip: true
				focus: true
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize + 1
				color: Config.foreground
				selectionColor: Config.settingsSelected
							onTextChanged: {
					if (searchInput.text !== win.query)
						win.query = searchInput.text;
					flick.contentY = 0;
				}

				Keys.onDownPressed: win.go(win.pages.length > 0 ? win.pages[0].name : "")
				Keys.onEscapePressed: searchInput.text = ""

				Text {
					anchors.verticalCenter: parent.verticalCenter
					visible: searchInput.text === ""
					font: searchInput.font
					color: Config.settingsLabel
					text: "Search"
				}
			}

			function clear() {
				searchInput.text = "";
			}
		}

		Flickable {
			anchors.top: search.bottom
			anchors.topMargin: 12
			anchors.bottom: parent.bottom
			x: 12
			width: parent.width - 24
			contentHeight: nav.height
			clip: true
			boundsBehavior: Flickable.StopAtBounds

			Column {
				id: nav

				width: parent.width
				spacing: 2

				Repeater {
					model: win.pages

					delegate: Item {
						id: entry

						required property var modelData

						readonly property bool chosen: !win.searching && win.page === entry.modelData.name

						width: nav.width
						height: 34

						Rectangle {
							anchors.fill: parent
							radius: 8
							color: entry.chosen ? Config.launcherHighlight : Config.settingsSelected
							opacity: entry.chosen ? 1 : (entryHover.containsMouse ? 0.5 : 0)

							Behavior on opacity {
								NumberAnimation {
									duration: Config.toggleMs
								}
							}
						}

						Rectangle {
							id: badge

							x: 6
							anchors.verticalCenter: parent.verticalCenter
							width: 24
							height: 24
							radius: 7
							color: entry.chosen ? Config.foreground : Config.toggleTrack

							Glyph {
								anchors.fill: parent
								size: Config.settingsFontSize
								color: entry.chosen ? Config.surface : Config.foreground
								glyph: Config.glyph(entry.modelData.glyph)
							}
						}

						Text {
							anchors.left: badge.right
							anchors.leftMargin: 10
							anchors.right: parent.right
							anchors.rightMargin: 8
							anchors.verticalCenter: parent.verticalCenter
							elide: Text.ElideRight
							font.family: Config.fontFamily
							font.pixelSize: Config.settingsFontSize + 1
							color: entry.chosen ? Config.foreground : Config.settingsLabel
							text: entry.modelData.name
						}

						MouseArea {
							id: entryHover

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: win.go(entry.modelData.name)
						}
					}
				}
			}
		}
	}

	Item {
		id: content

		anchors.left: sidebar.right
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom

		readonly property real column: Math.min(Config.settingsColumn, content.width - Config.settingsPadding * 2)

		Flickable {
			id: flick

			anchors.top: header.bottom
			anchors.bottom: parent.bottom
			width: parent.width
			contentWidth: width
			contentHeight: body.height + Config.settingsPadding + (win.barShown ? applyBar.height + Config.settingsGap * 2 : Config.settingsPadding)
			boundsBehavior: Flickable.StopAtBounds
			clip: true
			interactive: false

			Behavior on contentY {
				enabled: flick.easing

				NumberAnimation {
					duration: Config.popupSlideMs / 2
					easing.type: Easing.OutCubic
				}
			}

			property bool easing: false

			MouseArea {
				width: flick.width
				height: Math.max(flick.height, flick.contentHeight)
				acceptedButtons: Qt.NoButton
				onWheel: function (wheel) {
					flick.easing = false;
					flick.contentY = Calc.clamp(flick.contentY - wheel.angleDelta.y, 0, Math.max(0, flick.contentHeight - flick.height));
				}
			}

			Column {
				id: body

				width: content.column
				x: Math.round((flick.width - width) / 2)
				y: 8
				spacing: Config.settingsSectionGap

				Flow {
					visible: !win.searching && win.current.name === "Widgets"
					width: parent.width
					spacing: 6

					Repeater {
						model: win.widgetGroups

						delegate: Rectangle {
							id: chip

							required property var modelData

							readonly property bool chosen: win.widgetGroup === chip.modelData.name

							width: chipLabel.implicitWidth + 20
							height: 28
							radius: 14
							color: chip.chosen ? Config.launcherHighlight : (chipHover.containsMouse ? Config.settingsSelected : "transparent")

							Text {
								id: chipLabel

								anchors.centerIn: parent
								font.family: Config.fontFamily
								font.pixelSize: Config.settingsSmallSize
								color: chip.chosen ? Config.foreground : Config.settingsLabel
								text: chip.modelData.name
							}

							MouseArea {
								id: chipHover

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: win.widgetGroup = chip.modelData.name
							}
						}
					}
				}

				BarPreview {
					width: parent.width
					visible: !win.searching && win.current.sections.some(function (s) { return s.name === "bar"; })
					layout: win.layout
				}

				LayoutEditor {
					visible: !win.searching && win.current.sections.some(function (s) { return s.name === "bar"; })
					store: win
					library: win.library
				}

				DisplayPage {
					width: parent.width
					visible: !win.searching && win.current.name === "Display"
				}

				WallpaperPage {
					width: parent.width
					visible: !win.searching && win.current.name === "Wallpaper"
				}

				Repeater {
					model: win.searching ? win.found : win.pageSections

					delegate: Section {
						required property var modelData

						width: body.width
						section: modelData
						store: win
					}
				}

				Text {
					visible: !win.searching && win.pages.length === 0
					width: parent.width
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsFontSize + 1
					color: Config.settingsLabel
					text: "Settings needs the current yudaemond: restart it and reopen this window"
				}

				Text {
					visible: win.searching && win.found.length === 0
					width: parent.width
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsFontSize + 1
					color: Config.settingsLabel
					text: "Nothing matches"
				}
			}
		}

		Scrollbar {
			view: flick
		}

		Rectangle {
			id: header

			width: parent.width
			height: 56
			color: Config.surface

			Rectangle {
				anchors.bottom: parent.bottom
				width: parent.width
				height: 1
				color: Config.settingsRule
				opacity: flick.contentY > 0 ? 1 : 0

				Behavior on opacity {
					NumberAnimation {
						duration: Config.toggleMs
					}
				}
			}

			Item {
				x: Math.round((parent.width - content.column) / 2)
				width: content.column
				height: parent.height

				ArrowPill {
					id: arrow

					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					visible: flick.contentY > 0 || win.history.length > 0
					glyph: flick.contentY > 0 ? Config.iconUp : Config.iconChevron
					onClicked: {
						flick.easing = true;
						win.back();
					}
				}

				Text {
					anchors.left: arrow.visible ? arrow.right : parent.left
					anchors.leftMargin: arrow.visible ? 12 : 0
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					elide: Text.ElideRight
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsTitleSize - 4
					color: Config.foreground
					text: win.searching ? "Search" : win.current.name
				}
			}
		}

		Rectangle {
			id: applyBar

			width: content.column
			height: Config.settingsRowHeight + 8
			x: Math.round((content.width - width) / 2)
			y: win.barShown ? content.height - height - Config.settingsGap : content.height + 8
			radius: Config.settingsRadius
			color: Config.launcherHighlight

			Behavior on y {
				NumberAnimation {
					duration: Config.popupSlideMs / 2
					easing.type: Easing.OutCubic
				}
			}

			Text {
				anchors.left: parent.left
				anchors.leftMargin: Config.settingsGap + 4
				anchors.right: buttons.left
				anchors.rightMargin: Config.settingsGap
				anchors.verticalCenter: parent.verticalCenter
				elide: Text.ElideRight
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize + 1
				color: win.failed !== "" ? Config.red : Config.foreground
				text: win.failed !== "" ? "Could not save " + win.failed : "Changes are not applied yet"
			}

			Row {
				id: buttons

				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				spacing: 8

				Repeater {
					model: [{ label: "Revert", main: false }, { label: "Apply", main: true }]

					delegate: Rectangle {
						id: button

						required property var modelData

						width: buttonText.implicitWidth + 32
						height: Config.settingsChipHeight + 4
						radius: height / 2
						color: button.modelData.main ? (buttonHover.containsMouse ? Config.launcherHighlightText : Config.foreground) : (buttonHover.containsMouse ? Config.toggleHover : "transparent")

						Text {
							id: buttonText

							anchors.centerIn: parent
							font.family: Config.fontFamily
							font.pixelSize: Config.settingsFontSize + 1
							color: button.modelData.main ? Config.surface : Config.foreground
							text: button.modelData.label
						}

						MouseArea {
							id: buttonHover

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: button.modelData.main ? win.apply() : win.revert()
						}
					}
				}
			}
		}

		Text {
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Config.settingsGap
			anchors.horizontalCenter: parent.horizontalCenter
			visible: !win.manual && win.failed !== ""
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			color: Config.red
			text: "Could not save " + win.failed
		}
	}
}
