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

		Item {
			id: brand

			x: Config.settingsGap
			y: Config.settingsPadding
			width: parent.width - Config.settingsGap * 2
			height: Config.settingsRowHeight

			Glyph {
				id: brandGlyph

				x: 10
				anchors.verticalCenter: parent.verticalCenter
				width: 22
				height: 22
				size: Config.settingsTitleSize - 4
				color: Config.settingsAccent
				glyph: Config.glyph("settings")
			}

			Text {
				anchors.left: brandGlyph.right
				anchors.leftMargin: Config.settingsGap
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
			anchors.topMargin: Config.settingsGap * 2
			x: Config.settingsGap
			width: parent.width - Config.settingsGap * 2
			spacing: 2

			Repeater {
				model: Toml.categories

				delegate: Item {
					id: entry

					required property var modelData

					width: parent.width
					height: Config.settingsRowHeight

					Rectangle {
						anchors.fill: parent
						radius: Config.rowRadius
						color: Config.settingsSelected
						opacity: win.pane === entry.modelData.id ? 1 : (entryHover.containsMouse ? 0.5 : 0)
					}

					Glyph {
						id: entryGlyph

						x: 10
						anchors.verticalCenter: parent.verticalCenter
						width: 18
						height: 18
						size: Config.settingsFontSize + 1
						color: win.pane === entry.modelData.id ? Config.settingsAccent : Config.settingsLabel
						glyph: Config.glyph(entry.modelData.glyph)
					}

					Text {
						anchors.left: entryGlyph.right
						anchors.leftMargin: Config.settingsGap
						anchors.right: parent.right
						anchors.rightMargin: 10
						anchors.verticalCenter: parent.verticalCenter
						elide: Text.ElideRight
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsFontSize
						color: Config.foreground
						text: entry.modelData.name
					}

					MouseArea {
						id: entryHover

						anchors.fill: parent
						hoverEnabled: true
						onClicked: win.pane = entry.modelData.id
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
		anchors.bottom: footer.top

		Flickable {
			id: flick

			anchors.fill: parent
			contentWidth: width
			contentHeight: body.height + Config.settingsPadding * 2
			boundsBehavior: Flickable.StopAtBounds
			clip: true
			interactive: false

			MouseArea {
				width: flick.width
				height: flick.contentHeight
				acceptedButtons: Qt.NoButton
				onWheel: function (wheel) {
					flick.contentY = Calc.clamp(flick.contentY - wheel.angleDelta.y, 0, Math.max(0, flick.contentHeight - flick.height));
				}
			}

			Column {
				id: body

				x: Config.settingsPadding
				y: Config.settingsPadding
				width: flick.width - Config.settingsPadding * 2
				spacing: Config.settingsGap * 2

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
					width: displayPanel.implicitWidth
					height: displayPanel.implicitHeight
					radius: Config.settingsRadius
					color: Config.settingsCard

					DisplayPanel {
						id: displayPanel

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
	}

	Rectangle {
		id: footer

		anchors.left: sidebar.right
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Config.settingsRowHeight + Config.settingsGap * 2
		color: Config.surface

		Rectangle {
			width: parent.width
			height: 1
			color: Config.dim
		}

		Text {
			anchors.left: parent.left
			anchors.leftMargin: Config.settingsPadding
			anchors.right: buttons.left
			anchors.rightMargin: Config.settingsGap
			anchors.verticalCenter: parent.verticalCenter
			elide: Text.ElideRight
			visible: win.failed !== ""
			font.family: Config.fontFamily
			font.pixelSize: Config.settingsSmallSize
			color: Config.red
			text: "Could not save " + win.failed
		}

		Row {
			id: buttons

			anchors.right: parent.right
			anchors.rightMargin: Config.settingsPadding
			anchors.verticalCenter: parent.verticalCenter
			spacing: Config.settingsGap

			Repeater {
				model: [{ label: "Revert", run: win.revert, main: false }, { label: "Apply", run: win.apply, main: true }]

				delegate: Rectangle {
					id: button

					required property var modelData

					width: buttonText.implicitWidth + Config.settingsGap * 2
					height: Config.settingsChipHeight
					radius: Config.rowRadius
					color: button.modelData.main && win.dirty ? Config.settingsAccent : Config.launcherSearchBox
					opacity: win.dirty ? 1 : 0.4

					Text {
						id: buttonText

						anchors.centerIn: parent
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsFontSize
						color: button.modelData.main && win.dirty ? Config.surface : Config.foreground
						text: button.modelData.label
					}

					MouseArea {
						anchors.fill: parent
						enabled: win.dirty
						onClicked: button.modelData.run()
					}
				}
			}
		}
	}
}
