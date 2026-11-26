import QtQuick
import qs
import qs.ui

Column {
	id: root

	required property var auth

	width: Config.lockCardWidth

	component Pick: Item {
		id: pick

		property string glyph: ""
		property string text: ""
		property int count: 0

		signal stepped(int delta)

		width: root.width
		height: Config.lockMenuRowHeight

		IconButton {
			id: back

			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			visible: pick.count > 1
			size: Config.lockMenuTextSize
			box: Config.lockMenuRowHeight
			glyph: Config.iconChevron
			activeFocusOnTab: false
			onClicked: pick.stepped(-1)
		}

		Row {
			anchors.centerIn: parent
			spacing: Config.launcherGap

			Glyph {
				id: mark

				anchors.verticalCenter: parent.verticalCenter
				width: Config.lockMenuTextSize
				height: Config.lockMenuTextSize
				size: Config.lockMenuTextSize
				glyph: pick.glyph
			}

			Label {
				anchors.verticalCenter: parent.verticalCenter
				width: Math.min(implicitWidth, pick.width - Config.lockMenuRowHeight * 2 - mark.width - Config.launcherGap)
				font.pixelSize: Config.lockMenuTextSize
				text: pick.text
			}
		}

		IconButton {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			visible: pick.count > 1
			size: Config.lockMenuTextSize
			box: Config.lockMenuRowHeight
			glyph: Config.iconRight
			activeFocusOnTab: false
			onClicked: pick.stepped(1)
		}
	}

	Pick {
		glyph: Config.iconUser
		text: root.auth.userName
		count: root.auth.users.length
		onStepped: delta => root.auth.stepUser(delta)
	}

	Pick {
		glyph: Config.iconMonitor
		text: root.auth.sessionName
		count: root.auth.sessions.length
		onStepped: delta => root.auth.stepSession(delta)
	}
}
