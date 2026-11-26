import QtQuick
import qs
import qs.services
import qs.ui

Item {
	id: row

	required property var model
	property int index: 0
	property int columns: 1
	property real cell: Config.windowsGridCell
	property real iconSize: Config.windowsIconSize
	property real highlightSize: Config.windowsHighlightSize
	property real labelSize: Config.windowsTitleSize
	property string emptyMessage: ""
	property bool labeled: true
	property bool interactive: false

	readonly property bool hovered: hit.containsMouse
	readonly property int count: row.model ? row.model.length : 0
	readonly property int active: row.count === 0 ? -1 : Calc.clamp(row.index, 0, row.count - 1)
	readonly property real emptyWidth: row.count === 0 ? emptyLabel.implicitWidth : 0

	signal hover(int index)
	signal picked(int index)

	function at(x, y) {
		const column = Calc.clamp(Math.floor(x / row.cell), 0, row.columns - 1);
		const line = Math.floor(Math.min(y, grid.height - 1) / row.cell);
		return Calc.clamp(line * row.columns + column, 0, Math.max(0, row.count - 1));
	}

	implicitWidth: Math.max(row.columns * row.cell, row.emptyWidth)
	implicitHeight: Math.ceil(Math.max(row.count, 1) / row.columns) * row.cell + Config.windowsLabelGap + labelText.implicitHeight

	Item {
		id: grid

		width: Math.max(row.columns * row.cell, row.emptyWidth)
		height: Math.ceil(Math.max(row.count, 1) / row.columns) * row.cell
		clip: true

		Highlight {
			fillParent: false
			active: row.active >= 0
			x: (row.active % row.columns) * row.cell + (row.cell - row.highlightSize) / 2
			y: Math.floor(row.active / row.columns) * row.cell + (row.cell - row.highlightSize) / 2
			width: row.highlightSize
			height: row.highlightSize
			radius: 0
		}

		Repeater {
			model: row.model

			delegate: Item {
				id: cellItem

				required property var modelData
				required property int index

				readonly property string appIcon: modelData.appId !== undefined && modelData.appId !== "" ? AppIcons.iconOf(modelData.appId) : ""

				x: (cellItem.index % row.columns) * row.cell
				y: Math.floor(cellItem.index / row.columns) * row.cell
				width: row.cell
				height: row.cell

				Icon {
					anchors.centerIn: parent
					size: row.iconSize
					visible: cellItem.appIcon !== ""
					source: cellItem.appIcon
				}

				Text {
					anchors.centerIn: parent
					visible: cellItem.appIcon === "" && modelData.glyph !== undefined && modelData.glyph !== ""
					font.family: Config.fontFamily
					font.pixelSize: row.iconSize
					color: Config.foreground
					text: cellItem.modelData.glyph || ""
				}
			}
		}

		Text {
			id: emptyLabel

			anchors.centerIn: parent
			visible: row.count === 0
			font.family: Config.fontFamily
			font.pixelSize: Config.launcherFontSize
			color: Config.muted
			text: row.emptyMessage
		}
	}

	Text {
		id: labelText

		width: Math.min(implicitWidth, grid.width)
		x: row.active < 0 ? 0 : Calc.clamp(row.active * row.cell + (row.cell - width) / 2, 0, grid.width - width)
		anchors.top: grid.bottom
		anchors.topMargin: Config.windowsLabelGap
		horizontalAlignment: Text.AlignHCenter
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: row.labelSize
		color: Config.foreground
		opacity: row.labeled ? 1 : 0
		text: row.active >= 0 ? (row.model[row.active].name || "") : ""
	}

	MouseArea {
		id: hit

		anchors.fill: parent
		enabled: row.interactive && row.count > 0
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onPositionChanged: mouse => row.hover(row.at(mouse.x, mouse.y))
		onClicked: mouse => row.picked(row.at(mouse.x, mouse.y))
	}
}
