import QtQuick
import qs
import qs.ui

Item {
	id: root

	property string sizeClass: Metrics.sizeClass(Window.width)
	property real column: Metrics.column
	property bool flush: false
	property real topPadding: root.flush ? 0 : Metrics.gapSmall * 2
	property real bottomPadding: root.padding
	property real spacing: Metrics.sectionGap
	property alias contentY: scroll.contentY

	default property alias content: body.data

	readonly property real padding: root.flush ? 0 : Metrics.paddingFor(root.sizeClass)
	readonly property real lane: Math.max(0, Math.min(root.column, root.width - root.padding * 2))
	readonly property Flickable flickable: scroll.view
	readonly property bool scrolled: scroll.contentY > 0

	anchors.fill: parent

	function toTop() {
		scroll.toTop();
	}

	AppScroll {
		id: scroll

		anchors.fill: parent
		contentHeight: body.y + body.height + root.bottomPadding

		Column {
			id: body

			x: Math.round((root.width - root.lane) / 2)
			y: root.topPadding
			width: root.lane
			spacing: root.spacing
		}
	}
}
