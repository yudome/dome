pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit

AppWindow {
	id: win

	appTitle: "Settings"
	preset: "large"

	Store {
		id: settingsStore
	}

	AppAction {
		id: revertAction

		text: "Revert"
		kind: "ghost"
		onTriggered: settingsStore.revert()
	}

	AppAction {
		id: applyAction

		text: "Apply"
		kind: "primary"
		onTriggered: settingsStore.apply()
	}

	Connections {
		target: settingsStore

		function onQueryChanged() {
			if (side.query !== settingsStore.query)
				side.query = settingsStore.query;
		}

		function onPageChanged() {
			page.toTop();
		}
	}

	AppScaffold {
		id: scaffold

		anchors.fill: parent

		sidebar: AppSidebar {
			id: side

			searchable: true
			onQueryChanged: {
				settingsStore.query = side.query;
				page.toTop();
			}
			onSearchDown: if (settingsStore.pages.length > 0) settingsStore.go(settingsStore.pages[0].name)

			AppNav {
				model: settingsStore.pages
				current: settingsStore.searching ? undefined : settingsStore.page
				onPicked: function (name) {
					settingsStore.go(name);
					scaffold.closeDrawer();
				}
			}
		}

		header: AppHeader {
			title: settingsStore.searching ? "Search" : settingsStore.current.name
			back: page.scrolled || settingsStore.history.length > 0
			backIcon: page.scrolled ? "up" : "chevron"
			ruled: page.scrolled
			column: Metrics.column
			onBackClicked: page.scrolled ? page.toTop() : settingsStore.back()
		}

		footer: AppFooter {
			shown: settingsStore.barShown || (!settingsStore.manual && settingsStore.failed !== "")
			text: settingsStore.failed !== "" ? "Could not save " + settingsStore.failed : "Changes are not applied yet"
			tone: settingsStore.failed !== "" ? "danger" : "plain"
			actions: settingsStore.manual ? [revertAction, applyAction] : []
		}

		StateView {
			anchors.fill: parent
			status: settingsStore.status
			icon: "search"
			emptyText: "No matches"
			onRetry: settingsStore.load()

			AppPage {
				id: page

				Flow {
					visible: !settingsStore.searching && settingsStore.current.name === "Widgets"
					width: parent.width
					spacing: Metrics.gapSmall * 1.5

					Repeater {
						model: settingsStore.widgetGroups

						delegate: Chip {
							required property var modelData

							text: modelData.label
							selected: settingsStore.widgetGroup === modelData.value
							onClicked: settingsStore.widgetGroup = modelData.value
						}
					}
				}

				BarPreview {
					width: parent.width
					visible: !settingsStore.searching && settingsStore.hasBar
					layout: settingsStore.layout
					store: settingsStore
				}

				LayoutEditor {
					visible: !settingsStore.searching && settingsStore.hasBar
					store: settingsStore
					library: settingsStore.library
				}

				DisplayPage {
					width: parent.width
					visible: !settingsStore.searching && settingsStore.current.name === "Display"
					store: settingsStore
				}

				WallpaperPage {
					width: parent.width
					visible: !settingsStore.searching && settingsStore.current.name === "Wallpaper"
					store: settingsStore
				}

				Repeater {
					model: settingsStore.searching ? settingsStore.found : settingsStore.pageSections

					delegate: Section {
						required property var modelData

						section: modelData
						store: settingsStore
					}
				}
			}
		}
	}
}
