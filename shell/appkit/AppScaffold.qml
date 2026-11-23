import QtQuick
import qs
import qs.ui

Item {
	id: root

	property string sizeClass: Metrics.sizeClass(root.width)
	property bool drawerOpen: false
	property bool hasSidebar: sideSlot.children.length > 0
	property bool sidebarShown: true
	property bool headerShown: true
	property alias sidebarSize: split.size

	property alias sidebar: sideSlot.data
	property alias header: headSlot.data
	property alias footer: footSlot.data
	default property alias content: bodySlot.data

	readonly property bool compact: root.sizeClass === "compact"
	readonly property bool docked: root.hasSidebar && root.sidebarShown && !root.compact
	readonly property real headerHeight: root.headerShown && headSlot.children.length > 0 ? Metrics.headerHeight : 0

	onCompactChanged: root.drawerOpen = false

	function closeDrawer() {
		root.drawerOpen = false;
	}

	AppSplit {
		id: split

		anchors.fill: parent
		size: root.sizeClass === "wide" ? Metrics.sidebarWideWidth : Metrics.sidebarWidth
		collapsed: !root.docked

		second: Item {
			anchors.fill: parent

			Item {
				id: bodySlot

				y: root.headerHeight
				width: parent.width
				height: parent.height - root.headerHeight - footSlot.height
			}

			Item {
				id: footSlot

				anchors.bottom: parent.bottom
				width: parent.width
				height: footSlot.childrenRect.height
			}

			Item {
				id: headBar

				width: parent.width
				height: root.headerHeight
				visible: root.headerHeight > 0

				IconButton {
					id: drawerButton

					anchors.left: parent.left
					anchors.leftMargin: Metrics.paddingCompact / 2
					anchors.verticalCenter: parent.verticalCenter
					visible: root.compact && root.hasSidebar && root.sidebarShown
					name: "menu"
					label: "Sidebar"
					selected: root.drawerOpen
					onClicked: root.drawerOpen = !root.drawerOpen
				}

				Item {
					id: headSlot

					anchors.left: drawerButton.visible ? drawerButton.right : parent.left
					anchors.right: parent.right
					height: parent.height
				}
			}
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Config.surface
		opacity: root.compact && root.drawerOpen ? Config.appScrim : 0
		visible: opacity > 0

		Behavior on opacity {
			NumberAnimation {
				duration: Motion.fadeMs
			}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.closeDrawer()
		}
	}

	Rectangle {
		id: sideFrame

		x: root.compact ? (root.drawerOpen ? 0 : -width - Metrics.border) : 0
		width: root.compact ? Math.min(Metrics.sidebarWidth, root.width - Metrics.leading * 2) : split.paneWidth - Metrics.border
		height: root.height
		color: Config.surface
		visible: root.hasSidebar && root.sidebarShown && (root.docked || root.drawerOpen || x > -width)
		border.width: root.compact ? Metrics.border : 0
		border.color: Config.rule

		Behavior on x {
			enabled: root.compact

			NumberAnimation {
				duration: Motion.fadeMs
				easing.type: Motion.easing
			}
		}

		Item {
			id: sideSlot

			anchors.fill: parent
		}
	}
}
