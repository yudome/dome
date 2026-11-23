pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui

Item {
	id: root

	property bool shown: true
	property string text: ""
	property string tone: "plain"
	property var actions: []
	property var task: null

	default property alias trailing: extra.data

	width: parent ? parent.width : 0
	height: root.shown ? Metrics.headerHeight : 0
	clip: true

	Behavior on height {
		NumberAnimation {
			duration: Motion.toggleMs
			easing.type: Motion.easing
		}
	}

	Rectangle {
		width: parent.width
		height: Metrics.headerHeight
		color: AppPalette.surface

		Rectangle {
			width: parent.width
			height: Metrics.border
			color: AppPalette.rule
		}

		ProgressBar {
			anchors.top: parent.top
			width: parent.width
			visible: root.task !== null && root.task.total > 0
			task: root.task
		}

		Label {
			id: message

			anchors.left: parent.left
			anchors.leftMargin: Metrics.paddingFor(Metrics.sizeClass(Window.width))
			anchors.right: buttons.left
			anchors.rightMargin: Metrics.gap
			anchors.verticalCenter: parent.verticalCenter
			anchors.verticalCenterOffset: message.capOffset
			ink: root.tone === "danger" ? AppPalette.danger : root.tone === "warning" ? AppPalette.warning : AppPalette.ink
			text: root.text
		}

		Row {
			id: buttons

			anchors.right: parent.right
			anchors.rightMargin: Metrics.paddingFor(Metrics.sizeClass(Window.width))
			anchors.verticalCenter: parent.verticalCenter
			spacing: Metrics.gapSmall * 2

			Row {
				id: extra

				anchors.verticalCenter: parent.verticalCenter
				spacing: Metrics.gapSmall * 2
			}

			Repeater {
				model: root.actions

				delegate: Button {
					required property var modelData

					anchors.verticalCenter: parent ? parent.verticalCenter : undefined
					action: modelData
				}
			}
		}
	}
}
