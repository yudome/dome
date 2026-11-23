import QtQuick
import Quickshell
import qs.ui
import qs.panelkit
import qs
import qs.services

PanelPage {
	id: root

	property date today: clock.date
	property int weekStart: Config.calendarWeekStart
	property bool held: false

	readonly property var grid: Yudae.calendarState.rows || []
	readonly property bool arrowsShown: root.held || boxHover.hovered
	readonly property real gridWidth: Config.calendarCellWidth * 7
	readonly property string monthText: Yudae.calendarState.month || ""
	readonly property string yearText: Yudae.calendarState.year || ""
	readonly property var weekdays: Yudae.calendarState.weekdays || []
	readonly property real mondayInk: (Config.calendarCellWidth - weekdayMetrics.width) / 2 + weekdayMetrics.tightBoundingRect.x
	readonly property real titleX: root.mondayInk - monthMetrics.tightBoundingRect.x

	contentWidth: card.implicitWidth

	SystemClock {
		id: clock

		precision: SystemClock.Seconds
	}

	TextMetrics {
		id: monthMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.calendarMonthSize
		text: root.monthText
	}

	TextMetrics {
		id: weekdayMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.calendarWeekdaySize
		text: root.weekdays ? root.weekdays[0] : ""
	}

	onWeekStartChanged: Yudae.send({ cmd: { calendar: { weekStart: root.weekStart } } })

	onMonthTextChanged: {
		root.held = true;
		holdTimer.restart();
	}

	function step(days) {
		Yudae.send({ cmd: { calendar: { days: days } } });
	}

	function stepMonths(months) {
		Yudae.send({ cmd: { calendar: { months: months } } });
	}

	function reset() {
		Yudae.send({ cmd: { calendar: { reset: true } } });
	}

	function stepYears(years) {
		Yudae.send({ cmd: { calendar: { years: years } } });
	}

	Keys.onPressed: function (event) {
		Input.calendar(event, root);
	}

	Column {
		id: card

		width: root.gridWidth
		spacing: Config.calendarGap

		Item {
			id: box

			width: card.width
			height: Math.max(title.height, arrows.height)

			HoverHandler {
				id: boxHover
			}

			Row {
				id: title

				x: root.titleX
				anchors.verticalCenter: parent.verticalCenter
				spacing: Config.calendarTitleGap

				Label {
					id: month

					font.pixelSize: Config.calendarMonthSize
					ink: Config.calendarBase
					text: root.monthText
				}

				Label {
					id: yearLabel

					font.pixelSize: Config.calendarMonthSize
					ink: Config.calendarBase
					text: root.yearText
				}
			}

			Row {
				id: arrows

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				spacing: Config.calendarArrowGap

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					box: Config.calendarArrowSize
					size: Config.calendarArrowSize
					flat: true
					reveal: true
					shown: root.arrowsShown
					hitMargin: Config.calendarArrowSize / 2
					inkIdle: Config.calendarBase
					glyph: Config.iconPrev
					onClicked: root.stepMonths(-1)
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					box: Config.calendarArrowSize
					size: Config.calendarArrowSize
					flat: true
					reveal: true
					shown: root.arrowsShown
					hitMargin: Config.calendarArrowSize / 2
					inkIdle: Config.calendarBase
					glyph: Config.iconNext
					onClicked: root.stepMonths(1)
				}
			}
		}

		Column {
			id: calendar

			width: card.width
			spacing: 6

			Row {
				id: weekdays

				Repeater {
					model: root.weekdays

					delegate: Label {
						required property string modelData

						width: Config.calendarCellWidth
						height: Config.calendarCellHeight
						horizontalAlignment: Text.AlignHCenter
						verticalAlignment: Text.AlignVCenter
						font.pixelSize: Config.calendarWeekdaySize
						ink: Config.foreground
						text: modelData
					}
				}
			}

			Item {
				id: days

				width: calendar.width
				height: Config.calendarCellHeight * Config.calendarRows

				Repeater {
					model: Config.calendarRows * 7

					delegate: Item {
						id: cell

						required property int index

						readonly property var day: root.grid[Math.floor(cell.index / 7)][cell.index % 7]

						x: (cell.index % 7) * Config.calendarCellWidth
						y: Math.floor(cell.index / 7) * Config.calendarCellHeight
						width: Config.calendarCellWidth
						height: Config.calendarCellHeight

						Rectangle {
							anchors.fill: parent
							visible: cell.day.today
							color: Config.surfaceRaised
						}

						Rectangle {
							anchors.fill: parent
							visible: cell.day.cursor
							color: "transparent"
							border.width: Config.calendarCursorBorder
							border.color: Config.foreground
						}

						Label {
							anchors.centerIn: parent
							font.pixelSize: Config.calendarDaySize
							ink: !cell.day.outside || cell.day.today || cell.day.cursor ? Config.foreground : Config.dim
							text: cell.day.day
						}
					}
				}
			}
		}

		Row {
			id: band

			width: card.width
			spacing: Config.calendarGap

			DayDial {
				id: dial

				moment: root.today
				anchors.verticalCenter: parent.verticalCenter
			}

			Column {
				id: meters

				width: band.width - Config.calendarDialSize - Config.calendarGap
				spacing: Config.calendarMeterGap

				Repeater {
					model: Yudae.calendarState.meters || []

					delegate: Item {
						required property var modelData
						required property int index

						width: meters.width
						height: Config.calendarMeterRow

						Label {
							id: meterLabel

							anchors.verticalCenter: parent.verticalCenter
							width: Config.calendarMeterLabelWidth
							font.pixelSize: Config.calendarMeterLabelSize
							ink: Config.foreground
							text: modelData.icon + " " + modelData.label
						}

						Label {
							id: meterValue

							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							width: Config.calendarMeterValueWidth
							horizontalAlignment: Text.AlignRight
							font.pixelSize: Config.calendarMeterValueSize
							ink: Config.foreground
							text: modelData.pct + "%"
						}

						Rectangle {
							id: meterTrack

							anchors.left: meterLabel.right
							anchors.right: meterValue.left
							anchors.verticalCenter: parent.verticalCenter
							height: Config.calendarMeterHeight
							color: Config.dim

							Rectangle {
								width: Math.round(parent.width * modelData.pct / 100)
								height: parent.height
								color: Config.foreground
							}
						}
					}
				}
			}
		}
	}

	Timer {
		id: holdTimer

		interval: 1800
		onTriggered: root.held = false
	}
}
