import QtQuick
import qs
import qs.ui

Item {
	id: root

	property Flickable view: own
	property alias contentY: own.contentY
	property alias contentHeight: own.contentHeight
	property real bottomPadding: 0
	property bool byRow: false
	property real rowStep: 0
	property int scrollWidth: Config.scrollbarWidth

	default property alias content: holder.data

	readonly property bool attached: root.view !== own

	function toTop() {
		root.view.contentY = root.view.originY;
	}

	Flickable {
		id: own

		anchors.fill: parent
		visible: !root.attached
		enabled: !root.attached
		contentWidth: width
		contentHeight: holder.height + root.bottomPadding
		boundsBehavior: Flickable.StopAtBounds
		acceptedButtons: Qt.NoButton
		clip: true

		Item {
			id: holder

			width: own.width
			height: holder.childrenRect.y + holder.childrenRect.height
		}
	}

	Scrollbar {
		view: root.view
		edge: root
		byRow: root.byRow
		rowStep: root.rowStep
		thickness: root.scrollWidth
	}
}
