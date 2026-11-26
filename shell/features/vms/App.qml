pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit
import Yudae.Native

AppWindow {
	id: win

	property bool powerOpen: false
	property bool hardwareOpen: false
	property Item menuAnchor: null
	property string menuVm: ""
	property bool overlayShown: false

	readonly property bool focusMode: win.fullscreen && vms.live.length > 0

	appTitle: "Virtual Machine Manager"
	preset: "large"

	onAppClosed: vms.releaseOnClose()

	function closeMenus() {
		win.powerOpen = false;
		win.menuVm = "";
	}

	function openMenu(name, anchor) {
		const same = win.menuVm === name && win.powerOpen;
		win.closeMenus();
		if (same)
			return;
		vms.select(name);
		win.menuAnchor = anchor;
		win.menuVm = name;
		win.powerOpen = true;
	}

	function openHardware(name) {
		win.closeMenus();
		vms.select(name);
		win.hardwareOpen = true;
	}

	Store {
		id: vms
	}

	Shortcut {
		sequence: Config.vmOverlayKey
		context: Qt.ApplicationShortcut
		onActivated: win.overlayShown = !win.overlayShown
	}

	AppAction {
		id: takeAction

		text: "Take control"
		kind: "primary"
		enabled: vms.current.name !== undefined
		onTriggered: vms.take(vms.current.name)
	}

	AppAction {
		id: releaseAction

		text: "Release"
		kind: "primary"
		onTriggered: vms.release(vms.live)
	}

	AppScaffold {
		id: scaffold

		anchors.fill: parent
		sidebarShown: !win.focusMode
		headerShown: !win.focusMode

		sidebar: AppSidebar {
			title: "Machines"

			StateView {
				anchors.fill: parent
				status: vms.status
				icon: "vm"
				emptyText: "No machines"
				errorText: "Daemon unavailable"
				retryable: false

				ListView {
					id: list

					x: Metrics.gapSmall * 3
					width: parent.width - x * 2
					height: parent.height
					clip: true
					model: vms.vms
					spacing: Metrics.gapSmall / 2
					boundsBehavior: Flickable.StopAtBounds
					acceptedButtons: Qt.NoButton

					delegate: ListRow {
						id: row

						required property var modelData

						readonly property bool chosen: vms.selected === row.modelData.name

						width: list.width
						height: Metrics.rowHeight
						hoverable: true
						selected: row.chosen
						dim: !row.chosen
						icon: "vm"
						iconSize: Metrics.headingSize
						title: row.modelData.name
						subtitle: vms.sessionLabel(row.modelData)
						onActivated: {
							vms.select(row.modelData.name);
							win.hardwareOpen = false;
							scaffold.closeDrawer();
						}

						Icon {
							id: provider

							anchors.verticalCenter: parent.verticalCenter
							visible: provider.source !== ""
							size: Metrics.bodySize
							source: vms.providerIcon(row.modelData)
						}

						IconButton {
							anchors.verticalCenter: parent.verticalCenter
							reveal: true
							shown: row.hovered || win.menuVm === row.modelData.name
							name: "settings"
							label: "Hardware"
							onClicked: win.openHardware(row.modelData.name)
						}

						IconButton {
							id: powerButton

							anchors.verticalCenter: parent.verticalCenter
							reveal: true
							shown: row.hovered || win.menuVm === row.modelData.name
							selected: win.powerOpen && win.menuVm === row.modelData.name
							name: "powerOff"
							label: "Power"
							onClicked: win.openMenu(row.modelData.name, powerButton)
						}
					}
				}

				AppScroll {
					anchors.fill: list
					view: list
				}
			}
		}

		header: AppHeader {
			title: vms.current.name || ""
			back: win.hardwareOpen
			onBackClicked: win.hardwareOpen = false
			actions: win.hardwareOpen || vms.current.name === undefined ? [] : [vms.live.length > 0 ? releaseAction : takeAction]

			Chip {
				anchors.verticalCenter: parent.verticalCenter
				visible: vms.summary !== "" && !win.hardwareOpen
				hoverable: false
				icon: "cpu"
				text: vms.summary
			}
		}

		Item {
			anchors.fill: parent

			AppPage {
				id: stagePage

				visible: !win.hardwareOpen
				flush: win.focusMode
				column: width
				bottomPadding: 0

				Item {
					id: stageArea

					width: parent.width
					height: win.focusMode ? stagePage.height : Math.max(0, stagePage.height - stagePage.topPadding - stagePage.padding)

					Rectangle {
						id: stage

						width: win.focusMode ? stageArea.width : Math.min(stageArea.width, Math.round(stageArea.height * 16 / 9))
						height: win.focusMode ? stageArea.height : Math.round(width * 9 / 16)
						color: AppPalette.surface
						clip: true

						EmptyState {
							anchors.centerIn: parent
							visible: vms.live.length === 0
							icon: vms.running ? "" : "vm"
							source: vms.running ? vms.providerIcon(vms.current) : ""
							text: vms.running ? "Agents are working here" : "Off"
						}

						Loader {
							anchors.fill: parent
							active: vms.live.length > 0
							sourceComponent: displayComponent
						}

						Component {
							id: displayComponent

							VmDisplay {
								id: display

								anchors.fill: parent
								qmp: vms.displayQmp
								broker: vms.displayBroker
								overlay: win.overlayShown
								onErrorChanged: if (error.length > 0) console.warn("VmDisplay:", error)

								PerfOverlay {
									x: Metrics.gapSmall * 2
									y: Metrics.gapSmall * 2
									visible: win.overlayShown
									stats: display.stats
								}
							}
						}
					}
				}
			}

			AppPage {
				visible: win.hardwareOpen && !win.focusMode

				AppSection {
					title: "Hardware"

					Repeater {
						model: vms.hardware

						delegate: FormRow {
							id: setting

							required property var modelData
							required property int index

							width: parent.width
							label: setting.modelData.label
							last: setting.index === vms.hardware.length - 1

							IconButton {
								anchors.right: amount.left
								anchors.verticalCenter: parent.verticalCenter
								name: "remove"
								label: "Less"
								enabled: setting.modelData.value > setting.modelData.min
								onClicked: vms.configure(setting.modelData.key, Math.max(setting.modelData.min, setting.modelData.value - setting.modelData.step))
							}

							Label {
								id: amount

								anchors.right: more.left
								anchors.verticalCenter: parent.verticalCenter
								width: Metrics.controlWidth / 2.5
								role: "value"
								horizontalAlignment: Text.AlignHCenter
								text: setting.modelData.value + (setting.modelData.suffix ? " " + setting.modelData.suffix : "")
							}

							IconButton {
								id: more

								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								name: "add"
								label: "More"
								enabled: setting.modelData.value < setting.modelData.max
								onClicked: vms.configure(setting.modelData.key, Math.min(setting.modelData.max, setting.modelData.value + setting.modelData.step))
							}
						}
					}
				}
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		z: 9
		visible: win.powerOpen
		onPressed: function (mouse) {
			const anchor = win.menuAnchor;
			const point = anchor ? mapToItem(anchor, mouse.x, mouse.y) : null;
			const onAnchor = point && point.x >= 0 && point.y >= 0 && point.x <= anchor.width && point.y <= anchor.height;
			if (!onAnchor)
				win.closeMenus();
			mouse.accepted = false;
		}
	}

	ContextMenu {
		anchor: win.menuAnchor
		entries: vms.powerEntries
		z: 11
		visible: win.powerOpen && !win.focusMode
		onPicked: function (entry) {
			win.closeMenus();
			vms.power(entry.action);
		}
	}
}
