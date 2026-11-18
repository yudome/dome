pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs
import qs.services
import "features/lock"
import "features/greeter"

ShellRoot {
	id: greeterRoot

	property int focusIndex: 0
	property bool reveal: false

	Session {
		id: auth

		preview: Quickshell.env("QS_GREETER_PREVIEW") === "1"
		defaultUser: Quickshell.env("QS_GREETER_USER") || ""

		onModeChanged: if (auth.mode !== "locked")
			greeterRoot.reveal = false
	}

	FloatingWindow {
		visible: true
		color: Config.surface

		Stage {
			anchors.fill: parent
			source: auth
			focusIndex: greeterRoot.focusIndex
			reveal: greeterRoot.reveal

			onFocusPicked: function (index) {
				greeterRoot.focusIndex = index;
			}

			onRevealPicked: function (shown) {
				greeterRoot.reveal = shown;
			}
		}
	}
}
