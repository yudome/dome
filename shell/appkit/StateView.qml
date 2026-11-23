import QtQuick
import qs
import qs.ui

Item {
	id: root

	property string status: "ready"
	property string icon: ""
	property string emptyText: ""
	property string errorText: "Unavailable"
	property bool retryable: true

	default property alias content: ready.data

	signal retry()

	Item {
		id: ready

		anchors.fill: parent
		visible: root.status === "ready"
	}

	Braille {
		anchors.centerIn: parent
		visible: root.status === "loading"
		running: visible
		ink: AppPalette.inkMuted
	}

	Column {
		anchors.centerIn: parent
		width: Math.min(parent.width, Metrics.controlWidth)
		visible: root.status === "empty" || root.status === "error"
		spacing: Metrics.gap

		EmptyState {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: root.status === "error" ? "warning" : root.icon
			text: root.status === "error" ? root.errorText : root.emptyText
		}

		IconButton {
			anchors.horizontalCenter: parent.horizontalCenter
			visible: root.status === "error" && root.retryable
			name: "refresh"
			label: "Retry"
			onClicked: root.retry()
		}
	}
}
