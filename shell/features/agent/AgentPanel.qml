import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.ui
import qs.panelkit

// The agent panel: the work that is done, the agent itself, and the plan the
// agent runs on, side by side.
//
// The panel keeps one size, so the popup it lives in never changes size
// while it is open.
PanelPage {
	id: root

	property var source: null

	// The name the panel shows for the agent. It is typed in the panel and
	// kept in a file, so it survives a restart.
	readonly property string agentName: Yudae.agentName === "" ? Config.agentPanelTitle : Yudae.agentName

	onAgentNameChanged: nameField.text = root.agentName

	// A blank name falls back to the one the shell ships with, so the panel
	// never loses its title.
	function saveAgentName(value) {
		const name = String(value === undefined || value === null ? "" : value).trim();

		nameField.text = name === "" ? Config.agentPanelTitle : name;

		if (name !== Yudae.agentName)
			Yudae.cmd("agentName", { set: name });
	}

	// Why the plans are missing, when nothing could be read.
	readonly property string planError: Yudae.usageError !== "" ? Yudae.usageError : Yudae.codexError

	// The panel is on screen. Every time it opens the plan is asked for again,
	// so the windows of the allowance are current and not whatever was left
	// from the last time it was looked at.
	readonly property bool open: root.source ? root.source.popupVisible : true

	onOpenChanged: {
		Yudae.watchGaze(root.open);

		if (root.open) {
			Yudae.refresh();
		}
	}

	Component.onCompleted: Yudae.watchGaze(root.open)

	// The marks are drawn at the size of the screen, so a small svg stays
	// sharp instead of being scaled up from a small raster.
	readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1

	readonly property string state: Yudae.state
	readonly property string stateText: root.state === "working"
		? Config.agentWorkingText
		: root.state === "blocked"
			? Config.agentBlockedText
			: root.state === "error"
				? Config.agentErrorText
				: Config.agentIdleText

	// The height of one row of work.
	readonly property real rowHeight: Config.fontSize + 6

	// The face sits in the popup's own window, which covers the screen, so the
	// pointer is tracked against the panel's position on that screen.
	readonly property point faceCenter: {
		const win = root.Window.window;

		if (!win)
			return Qt.point(0, 0);

		const at = face.mapToItem(win.contentItem, face.width / 2, face.height / 2);
		const screen = root.source && root.source.bar ? root.source.bar.screen : null;
		const originX = screen ? screen.x : 0;
		const originY = screen ? screen.y : 0;

		return Qt.point(originX + at.x, originY + at.y);
	}

	// The pointer is read through a curve that rises quickly while it is near
	// the face and levels off as it gets far, so the eyes answer a pointer
	// close by without slamming into the end of their travel.
	readonly property real gazeArm: Config.agentFaceSize * 2.5

	readonly property real gazeX: {
		if (!Yudae.cursor.valid)
			return 0;

		return Math.tanh((Yudae.cursor.x - root.faceCenter.x) / root.gazeArm);
	}

	readonly property real gazeY: {
		if (!Yudae.cursor.valid)
			return 0;

		return Math.tanh((Yudae.cursor.y - root.faceCenter.y) / (root.gazeArm * 2));
	}

	contentWidth: Config.agentPanelWidth
	contentHeight: workArea.y + Math.max(doneList.y + doneList.height, planStack.height)

	clip: true

	// The clock the countdowns read, so a panel that sits open does not keep
	// showing a reset time that has already gone by.
	property real now: Date.now()

	// The message the agent is asking about, and the one that was put away.
	// A new message comes back on its own.
	property string detail: Yudae.detailText
	property string dismissedDetail: ""

	readonly property bool detailHidden: root.detail !== "" && root.dismissedDetail === root.detail;

	function dismissDetail() {
		root.dismissedDetail = root.detail;
	}

	Timer {
		interval: 30000
		repeat: true
		running: true
		triggeredOnStart: true

		onTriggered: root.now = Date.now()
	}

	function countdown(text) {
		const at = Date.parse(String(text || ""));

		if (!isFinite(at))
			return "";

		const minutes = Math.floor((at - root.now) / 60000);

		if (minutes <= 0)
			return "now";

		const days = Math.floor(minutes / 1440);

		if (days > 0)
			return days + "d";

		const hours = Math.floor(minutes / 60);

		if (hours > 0)
			return hours + "h";

		return minutes + "m";
	}

	Item {
		id: body

		anchors.fill: parent

		property int tab: 0

		Item {
			id: header

			anchors.top: parent.top
			anchors.left: parent.left
			anchors.right: parent.right

			height: Math.max(face.height, stateBox.height)

			Item {
				id: face

				anchors.top: parent.top
				anchors.left: parent.left

				width: Config.agentFaceSize
				height: Config.agentFaceSize

				AgentFace {
					anchors.fill: parent

					size: Config.agentFaceSize
					state: root.state
					followCursor: true
					gazeX: root.gazeX
					gazeY: root.gazeY

					live: root.source ? root.source.popupVisible : true
					paused: root.source ? !root.source.popupVisible : false

					paintEyes: true

					bodyColor: Config.foreground
					eyeColor: Config.surface
				}

			}

			Column {
				id: stateBox

				anchors.left: face.right
				anchors.leftMargin: 12
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter

				spacing: 2

				InlineEdit {
					id: nameField

					width: parent.width
					height: root.rowHeight
					verticalAlignment: TextInput.AlignVCenter
					selectByMouse: true
					selectOnFocus: false

					text: root.agentName

					onAccepted: root.saveAgentName(nameField.text)
					onCancelled: root.saveAgentName(nameField.text)
					onFocusLost: root.saveAgentName(nameField.text)
				}

				Row {
					height: root.rowHeight
					spacing: 5

					Braille {
						anchors.verticalCenter: parent.verticalCenter
						visible: root.state === "working"
						running: root.state === "working" && root.open
						ink: Config.muted
					}

					Label {
						anchors.verticalCenter: parent.verticalCenter

						ink: root.state === "error" ? Config.red : Config.muted
						text: Yudae.online ? root.stateText : root.stateText + " (offline)"
					}
				}

				Row {
					height: root.rowHeight
					visible: root.detail !== "" && !root.detailHidden
					spacing: 6

					Label {
						anchors.verticalCenter: parent.verticalCenter
						width: Math.min(implicitWidth, stateBox.width - 24)
						elide: Text.ElideRight

						ink: Config.muted
						text: root.detail
					}

					IconButton {
						anchors.verticalCenter: parent.verticalCenter
						box: Config.fontSize + Config.gapsIn * 2
						size: Config.appCaptionSize
						name: "close"
						label: "Dismiss"
						onClicked: root.dismissDetail()
					}
				}
			}
		}

		Tabs {
			id: tabs

			anchors.top: header.bottom
			anchors.topMargin: 10
			anchors.left: parent.left
			height: Config.rowHeight
			model: [{ label: Config.agentTasksTitle, value: 0 }, { label: Config.agentPlanTitle, value: 1 }]
			current: body.tab
			onPicked: function (value) { body.tab = value; }
		}

		Rectangle {
			id: tabLine

			anchors.top: tabs.bottom
			anchors.left: parent.left
			anchors.right: parent.right

			height: 1
			color: Config.dim
		}

		Item {
			id: workArea

			anchors.top: tabLine.bottom
			anchors.topMargin: 8
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom

			Item {
				id: tasksBox

				anchors.fill: parent
				visible: body.tab === 0

				readonly property int listRows: 3
				readonly property real listHeight: tasksBox.listRows * (root.rowHeight + 2)

				Item {
					id: planRingStrip

					anchors.top: parent.top
					anchors.left: parent.left
					anchors.right: parent.right

					height: Yudae.planRings.length > 0 ? Config.agentRingSize : 0

					Row {
						visible: Yudae.planRings.length > 0

						spacing: Config.agentRingGap

						Repeater {
							model: Yudae.planRings

							delegate: Item {
								id: planRing

								required property var modelData

								width: Config.agentRingSize
								height: Config.agentRingSize

								StepBar {
									anchors.fill: parent

									circular: true
									ringWidth: Config.agentRingWidth
									level: planRing.modelData.percent / 100
									ink: planRing.modelData.percent >= Config.agentRingAlarmPercent ? Config.red : Config.yellow
									track: Config.dim
								}

								Image {
									visible: planRing.modelData.icon !== ""
									width: Math.round(Config.agentRingSize * 0.5)
									height: width
									x: Math.round((parent.width - width) / 2)
									y: Math.round((parent.height - height) / 2)

									source: planRing.modelData.icon === ""
										? ""
										: "file://" + Quickshell.shellDir + "/assets/providers/" + planRing.modelData.icon + ".svg?v=4"
									sourceSize.width: Math.round(width * root.dpr)
									sourceSize.height: Math.round(height * root.dpr)
									fillMode: Image.PreserveAspectFit
								}
							}
						}
					}
				}

				Label {
					id: workTitle

					anchors.top: planRingStrip.bottom
					anchors.topMargin: Yudae.planRings.length > 0 ? 8 : 0
					anchors.left: parent.left

					ink: Config.muted
					text: Config.agentWorkingText
				}

				StepList {
					id: workList

					shown: tasksBox.listRows

					anchors.top: workTitle.bottom
					anchors.topMargin: 4
					anchors.left: parent.left
					anchors.right: parent.right

					height: tasksBox.listHeight

					clip: true
					spacing: 2
					model: Yudae.working

					delegate: AgentRow {
						required property var modelData

						width: workList.width
						height: root.rowHeight

						kind: modelData.working ? "working" : (modelData.question ? "question" : "failed")
						icon: modelData.icon
						title: modelData.title
					}
				}

				Label {
					id: doneTitle

					anchors.top: workList.bottom
					anchors.topMargin: 6
					anchors.left: parent.left

					ink: Config.muted
					text: Config.agentDoneTitle
				}

				StepList {
					id: doneList

					shown: tasksBox.listRows

					anchors.top: doneTitle.bottom
					anchors.topMargin: 4
					anchors.left: parent.left
					anchors.right: parent.right

					height: tasksBox.listHeight

					clip: true
					spacing: 2
					model: Yudae.doneSessions

					delegate: AgentRow {
						required property var modelData

						width: doneList.width
						height: root.rowHeight

						kind: "done"
						icon: modelData.icon
						title: modelData.title
						dismissable: true

						onDismissed: Yudae.dismiss(modelData.id)
					}
				}

			}

			Item {
				id: planBox

				anchors.fill: parent
				visible: body.tab === 1

				Column {
					id: planStack

					anchors.top: parent.top
					anchors.left: parent.left
					anchors.right: parent.right
					spacing: 6

					// One block for each plan the shell knows about: its
					// name, and the windows of what is left of it.
					Repeater {
						model: Yudae.plans

						delegate: Column {
							id: planBlock

							required property var modelData

							width: planStack.width
							spacing: 6

							Row {
								spacing: 6

								Image {
									visible: planBlock.modelData.icon !== ""
									width: 18
									height: 18

									source: planBlock.modelData.icon === ""
										? ""
										: "file://" + Quickshell.shellDir + "/assets/providers/" + planBlock.modelData.icon + ".svg?v=4"
									sourceSize.width: Math.round(18 * root.dpr)
									sourceSize.height: Math.round(18 * root.dpr)
									fillMode: Image.PreserveAspectFit
								}

								Label {
									ink: Config.foreground
									text: planBlock.modelData.title
								}
							}

							Label {
								width: planBlock.width
								visible: planBlock.modelData.failure !== ""
								elide: Text.ElideRight

								ink: Config.muted
								text: planBlock.modelData.failure
							}

							Repeater {
								model: planBlock.modelData.limits

								delegate: Item {
									id: limitRow

									required property var modelData

									width: planBlock.width
									height: Math.max(limitLabel.implicitHeight, limitReset.implicitHeight)

									readonly property bool alarming: modelData.percent >= 90

									// The label and the numbers are fixed columns, so
									// every bar starts and ends in the same place. The
									// percentage sits before the bar, so the bar is
									// read as the rest.
									Label {
										id: limitLabel

										anchors.left: parent.left
										anchors.verticalCenter: parent.verticalCenter
										width: 68

										ink: Config.foreground
										text: modelData.title
									}

									StepBar {
										id: limitMeter

										anchors.left: limitLabel.right
										anchors.right: limitValue.left
										anchors.leftMargin: 8
										anchors.rightMargin: 10
										anchors.verticalCenter: parent.verticalCenter

										level: modelData.percent / 100
										ink: limitRow.alarming ? Config.red : Config.foreground
										track: Config.dim
									}

									Label {
										id: limitValue

										anchors.right: limitReset.left
										anchors.rightMargin: 6
										anchors.verticalCenter: parent.verticalCenter
										width: 34

										horizontalAlignment: Text.AlignRight

										ink: limitRow.alarming ? Config.red : Config.muted
										text: Math.round(modelData.percent) + "%"
									}

									Label {
										id: limitReset

										anchors.right: parent.right
										anchors.verticalCenter: parent.verticalCenter
										width: 26

										horizontalAlignment: Text.AlignRight

										ink: Config.muted
										text: root.countdown(modelData.resetsAt)
									}
								}
							}
						}
					}

					Label {
						width: parent.width
						visible: Yudae.plans.length === 0 && root.planError !== "" && root.planError !== "expired"
						elide: Text.ElideRight

						ink: Config.muted
						text: root.planError
					}
				}
			}
		}
	}
}
