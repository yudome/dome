pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit

AppWindow {
	id: win

	appTitle: "Disk"
	preset: "large"

	Store {
		id: disk
	}

	AppScaffold {
		id: scaffold

		anchors.fill: parent

		sidebar: AppSidebar {
			title: "Selected"

			SelectionSidebar {
				store: disk
			}
		}

		header: AppHeader {
			title: "Disk"
			actions: [disk.scanAction]

			Tabs {
				anchors.verticalCenter: parent.verticalCenter
				model: [{ label: "Map", value: "map" }, { label: "Packages", value: "packages" }, { label: "Caches", value: "caches" }]
				current: disk.tab
				onPicked: function (value) { disk.selectTab(value); }
			}
		}

		footer: AppFooter {
			shown: disk.job.total > 0
			task: disk.job
			text: disk.job.running ? "Cleaning " + disk.job.label : disk.job.failed > 0 ? disk.job.failed + " failed" : "Cleaned"
			tone: disk.job.failed > 0 ? "warning" : "plain"
		}

		Item {
			anchors.fill: parent

			AppPage {
				id: mapPage

				visible: disk.tab === "map"
				column: width
				spacing: Metrics.gap
				bottomPadding: 0

				Item {
					width: parent.width
					height: Metrics.chipHeight

					Breadcrumb {
						anchors.left: parent.left
						anchors.right: usage.left
						anchors.rightMargin: Metrics.gap
						anchors.verticalCenter: parent.verticalCenter
						segments: disk.crumbs
						onPicked: function (path) { disk.openPath(path); }
					}

					Column {
						id: usage

						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						width: Math.min(Metrics.controlWidth * 0.75, parent.width / 3)
						spacing: Metrics.gapSmall

						ProgressBar {
							width: parent.width
							value: disk.usedRatio
						}

						Label {
							width: parent.width
							role: "caption"
							horizontalAlignment: Text.AlignRight
							text: disk.usage
						}
					}
				}

				StateView {
					width: parent.width
					height: Math.max(0, mapPage.height - mapPage.topPadding - Metrics.chipHeight - Metrics.gap - mapPage.padding)
					status: disk.mapStatus
					icon: "disk"
					emptyText: disk.mapEmpty
					hint: disk.mapHint
					onRetry: disk.scan()

					Bubbles {
						anchors.fill: parent
						clip: true
						items: disk.entries
						selected: disk.mapSelection
						onToggled: function (item) { disk.toggleMapItem(item); }
						onActivated: function (item) {
							if (item.kind === "dir")
								disk.openPath(item.path);
						}
					}
				}
			}

			StateView {
				anchors.fill: parent
				visible: disk.tab === "packages"
				status: !disk.packagesLoaded ? "loading" : disk.packageRows.length === 0 ? "error" : "ready"
				errorText: "No packages"
				retryText: "Load packages"
				onRetry: disk.loadPackages()

				RowList {
					anchors.fill: parent
					rows: disk.packageItems
					selected: disk.packageSelection
					onToggled: function (row) { disk.togglePackage(row.raw); }
				}
			}

			StateView {
				anchors.fill: parent
				visible: disk.tab === "caches"
				status: !disk.cachesLoaded ? "loading" : disk.cacheRows.length === 0 ? "error" : "ready"
				errorText: "No caches"
				retryText: "Load caches"
				onRetry: disk.loadCaches()

				RowList {
					anchors.fill: parent
					rows: disk.cacheItems
					selected: disk.cacheSelection
					onToggled: function (row) { disk.toggleCache(row.raw); }
				}
			}
		}
	}
}
