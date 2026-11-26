import QtQuick
import Quickshell
import qs
import qs.ui
import qs.appkit

Item {
	id: root

	required property var view

	readonly property var store: root.view.store
	readonly property bool choosing: root.view.greeter && root.store.choosing

	SystemClock {
		id: clock

		precision: Config.lockClockFormat.indexOf("s") >= 0 ? SystemClock.Seconds : SystemClock.Minutes
	}

	HyprBorder {
		id: card

		anchors.horizontalCenter: parent.horizontalCenter
		anchors.verticalCenter: parent.verticalCenter
		width: Config.lockCardWidth + card.inset * 2
		height: column.implicitHeight + card.inset * 2
		padding: Config.launcherPadding
		backgroundColor: Config.surfaceTranslucent

		Connections {
			target: root.store

			function onShook() {
				shake.restart();
			}
		}

		SequentialAnimation {
			id: shake

			loops: 2
			NumberAnimation { target: card; property: "anchors.horizontalCenterOffset"; to: Config.launcherPadding; duration: Motion.toggleMs / 2 }
			NumberAnimation { target: card; property: "anchors.horizontalCenterOffset"; to: -Config.launcherPadding; duration: Motion.toggleMs }
			NumberAnimation { target: card; property: "anchors.horizontalCenterOffset"; to: 0; duration: Motion.toggleMs / 2 }
		}

		Column {
			id: column

			width: parent.width
			visible: !root.choosing
			spacing: Config.launcherGap

			Label {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				font.pixelSize: Config.lockClockSize
				font.weight: Font.Medium
				font.features: ({ "tnum": 1 })
				text: Qt.formatTime(clock.date, Config.lockClockFormat)
			}

			Label {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				font.pixelSize: Config.lockDateSize
				ink: Config.muted
				text: Qt.formatDate(clock.date, Config.lockDateFormat)
			}

			SearchField {
				width: parent.width
				boxHeight: Config.lockFieldHeight
				glyph: Config.iconLock
				size: Config.launcherFontSize
				echoMode: root.store.reveal ? TextInput.Normal : TextInput.Password
				text: root.store.password
				hintKey: root.store.mode === "checking" ? "" : "↵"
				hintText: Config.lockUnlockHint
				placeholder: root.store.mode === "checking" ? Config.lockCheckingText : ""

				MouseArea {
					anchors.fill: parent
					onClicked: root.store.wake()
				}

				IconButton {
					anchors.right: parent.right
					anchors.rightMargin: Config.gapsIn
					anchors.verticalCenter: parent.verticalCenter
					box: Config.lockFieldHeight - Config.gapsIn * 2
					glyph: root.store.reveal ? Config.iconEyeOff : Config.iconEye
					activeFocusOnTab: false
					onClicked: root.store.reveal = !root.store.reveal
				}
			}

			Label {
				width: parent.width
				visible: root.store.message !== ""
				horizontalAlignment: Text.AlignHCenter
				role: "caption"
				ink: Config.red
				text: root.store.message
			}

			IconRow {
				id: power

				property int at: -1
				readonly property var actions: root.view.greeter ? [{ name: "Switch", glyph: Config.iconUser }].concat(root.store.actions) : root.store.actions

				anchors.horizontalCenter: parent.horizontalCenter
				columns: power.actions.length
				cell: Config.lockCellSize
				iconSize: Math.round(power.cell * Config.powerIconSize / Config.powerCellSize)
				highlightSize: power.hovered ? Math.round(power.cell * Config.powerHighlightSize / Config.powerCellSize) : 0
				labelSize: Config.powerLabelSize
				labeled: power.hovered
				model: power.actions
				index: Math.max(0, power.at)
				interactive: true
				onHover: index => power.at = index
				onPicked: index => {
					const action = power.actions[index];
					if (action.power)
						root.store.power(action.power);
					else
						root.store.choosing = true;
				}
			}
		}

		Item {
			id: menu

			width: parent.width
			height: column.implicitHeight
			visible: root.choosing

			IconButton {
				glyph: Config.iconReturn
				label: "Back"
				size: Config.lockMenuTextSize
				box: Config.lockMenuRowHeight
				onClicked: root.store.choosing = false
			}

			Loader {
				anchors.centerIn: parent
				active: root.view.greeter
				sourceComponent: Choices {
					auth: root.view.auth
				}
			}
		}
	}
}
