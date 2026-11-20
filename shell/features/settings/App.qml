pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.ui
import "../display"
import "Toml.js" as Toml

AppWindow {
	id: win

	appTitle: "Settings"
	appMinWidth: 900
	appMinHeight: 560
	implicitWidth: 1180
	implicitHeight: 780

	property string pane: {
		const wanted = Quickshell.env("YUDAE_PANE") || "";
		return Toml.categories.some(function (c) { return c.id === wanted; }) ? wanted : "appearance";
	}
	property var doc: ({ sections: [], values: {} })
	property var layoutDoc: null
	property var pending: ({})
	property var pendingLayout: null
	property var features: ({})
	property string failed: ""

	readonly property var layout: win.pendingLayout || win.layoutDoc
	readonly property bool dirty: Object.keys(win.pending).length > 0 || win.pendingLayout !== null
	readonly property bool barShown: win.dirty || win.failed !== ""
	readonly property var category: Toml.categories.find(function (c) { return c.id === win.pane; })
	readonly property var library: Object.keys(win.features).sort().map(function (id) { return win.features[id]; })
	readonly property var glyphs: {
		const out = {};
		win.library.forEach(function (f) { out[f.id] = f.glyph; });
		return out;
	}
	readonly property var sections: win.category.sections.map(function (name) {
		return win.doc.sections.find(function (s) { return s.name === name; });
	}).filter(function (s) { return s !== undefined; })

	function value(key) {
		return win.pending[key] !== undefined ? win.pending[key] : win.doc.values[key];
	}

	function setValue(key, next) {
		const out = Object.assign({}, win.pending);
		if (next === win.doc.values[key])
			delete out[key];
		else
			out[key] = next;
		win.pending = out;
	}

	function setLayout(next) {
		win.pendingLayout = JSON.stringify(next) === JSON.stringify(Toml.copyLayout(win.layoutDoc)) ? null : next;
	}

	function apply() {
		win.failed = "";
		const keys = Object.keys(win.pending);
		const values = Object.assign({}, win.doc.values, win.pending);
		keys.forEach(function (key) {
			const next = win.pending[key];
			Yudae.request("settings", "set", { key: key, value: next }, function (result) {
				if (result === null)
					win.failed = key;
			});
		});
		if (win.pendingLayout !== null) {
			const next = win.pendingLayout;
			Yudae.request("bar", "layout", { layout: next }, function (result) {
				if (result === null)
					win.failed = "layout";
			});
			win.layoutDoc = next;
		}
		win.doc = { sections: win.doc.sections, values: values };
		win.pending = {};
		win.pendingLayout = null;
	}

	function revert() {
		win.pending = {};
		win.pendingLayout = null;
		win.failed = "";
	}

	FileView {
		path: Quickshell.shellDir + "/config.toml"
		watchChanges: true
		printErrors: false

		onFileChanged: this.reload()
		onLoaded: win.doc = Toml.parse(this.text())
	}

	FileView {
		path: Quickshell.shellDir + "/topbarlayout.json"
		watchChanges: true
		printErrors: false

		onFileChanged: this.reload()
		onLoaded: {
			try {
				win.layoutDoc = Toml.copyLayout(JSON.parse(this.text()));
			} catch (error) {
				win.layoutDoc = Toml.copyLayout({});
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

		Item {
			id: brand

			x: Config.settingsGap
			y: Config.settingsPadding - 6
			width: parent.width - Config.settingsGap * 2
			height: Config.settingsRowHeight

			Glyph {
				id: brandGlyph

				x: 10
				anchors.verticalCenter: parent.verticalCenter
				width: 20
				height: 20
				size: Config.settingsFontSize + 5
				color: Config.settingsInk
				glyph: Config.glyph("settings")
			}

			Text {
				anchors.left: brandGlyph.right
				anchors.leftMargin: 12
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				elide: Text.ElideRight
				font.family: Config.fontFamily
				font.pixelSize: Config.settingsFontSize + 3
				color: Config.foreground
				text: "Settings"
			}
		}

		Column {
			anchors.top: brand.bottom
			anchors.topMargin: Config.settingsGap
			x: Config.settingsGap
			width: parent.width - Config.settingsGap * 2
			spacing: 2

			Repeater {
				model: Toml.categories

				delegate: Item {
					id: entry

					required property var modelData

					readonly property bool current: win.pane === entry.modelData.id

					width: parent.width
					height: 36

					Rectangle {
						anchors.fill: parent
						radius: 8
						color: Config.settingsSelected
						opacity: entry.current ? 1 : (entryHover.containsMouse ? 0.45 : 0)

						Behavior on opacity {
							NumberAnimation {
								duration: Config.toggleMs
							}
						}
					}

					Glyph {
						id: entryGlyph

						x: 10
						anchors.verticalCenter: parent.verticalCenter
						width: 18
						height: 18
						size: Config.settingsFontSize + 1
						color: entry.current ? Config.foreground : Config.settingsLabel
						glyph: Config.glyph(entry.modelData.glyph)
					}

					Text {
						anchors.left: entryGlyph.right
						anchors.leftMargin: 12
						anchors.right: parent.right
						anchors.rightMargin: 10
						anchors.verticalCenter: parent.verticalCenter
						elide: Text.ElideRight
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsFontSize + 1
						color: entry.current ? Config.foreground : Config.settingsLabel
						text: entry.modelData.name
					}

					MouseArea {
						id: entryHover

						anchors.fill: parent
						hoverEnabled: true
						onClicked: {
							win.pane = entry.modelData.id;
							flick.contentY = 0;
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

		Flickable {
			id: flick

			anchors.fill: parent
			contentWidth: width
			contentHeight: body.height + Config.settingsPadding * 2 + (win.barShown ? applyBar.height + Config.settingsGap : 0)
			boundsBehavior: Flickable.StopAtBounds
			clip: true
			interactive: false

			MouseArea {
				width: flick.width
				height: Math.max(flick.height, flick.contentHeight)
				acceptedButtons: Qt.NoButton
				onWheel: function (wheel) {
					flick.contentY = Calc.clamp(flick.contentY - wheel.angleDelta.y, 0, Math.max(0, flick.contentHeight - flick.height));
				}
			}

			Column {
				id: body

				width: Math.min(Config.settingsColumn, flick.width - Config.settingsPadding * 2)
				x: Math.round((flick.width - width) / 2)
				y: Config.settingsPadding
				spacing: Config.settingsSectionGap

				Text {
					width: parent.width
					elide: Text.ElideRight
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsTitleSize
					color: Config.foreground
					text: win.category.name
				}

				BarPreview {
					width: parent.width
					visible: win.pane === "appearance" || win.pane === "bar"
					store: win
					layout: win.layout
					glyphs: win.glyphs
				}

				LayoutEditor {
					visible: win.pane === "bar"
					store: win
					library: win.library
				}

				Rectangle {
					visible: win.pane === "display"
					width: displayPanel.implicitWidth + 8
					height: displayPanel.implicitHeight + 8
					radius: Config.settingsRadius
					color: Config.settingsCard

					DisplayPanel {
						id: displayPanel

						x: 4
						y: 4
						shown: win.pane === "display"
					}
				}

				Repeater {
					model: win.sections

					delegate: Section {
						required property var modelData

						width: body.width
						section: modelData
						store: win
					}
				}
			}
		}

		Scrollbar {
			view: flick
		}

		Rectangle {
			id: applyBar

			width: Math.min(Config.settingsColumn, content.width - Config.settingsPadding * 2)
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
					model: [{ label: "Revert", run: win.revert, main: false }, { label: "Apply", run: win.apply, main: true }]

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
							onClicked: button.modelData.run()
						}
					}
				}
			}
		}
	}
}
