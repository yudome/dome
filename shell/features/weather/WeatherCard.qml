import QtQuick
import qs.ui
import qs.panelkit
import qs
import qs.services

PanelPage {
	id: root

	HoverHandler {
		id: cardHover
	}

	property bool editing: false
	property bool adding: false
	property bool held: false
	property string query: ""
	property int pickIndex: 0

	readonly property var now: Weather.current || {}
	readonly property var rows: Weather.days || []
	readonly property bool loading: root.now.loading === true
	readonly property string savedPlace: String(Weather.places[Weather.index] || "").split(",")[0].trim()
	readonly property string placeName: root.now.place ? root.now.place : root.savedPlace
	readonly property string tempValue: root.loading || !root.now.tempValue ? "--" : root.now.tempValue
	readonly property string tempUnit: root.loading || !root.now.tempUnit ? "" : root.now.tempUnit
	readonly property var match: root.suggestionRows.length > 0 ? root.suggestionRows[0] : null
	readonly property var suggestionRows: Weather.matches
	readonly property bool headerShown: root.editing || root.held || cardHover.hovered
	readonly property int dayCount: root.rows.length > 0 ? Math.min(root.rows.length, 7) : 7
	readonly property real dayTextWidth: dayTempMetrics.width * 1.04 + 2
	readonly property real dayCellWidth: Math.max(1, (card.width - Config.weatherDayGap * (root.dayCount - 1)) / root.dayCount)
	readonly property real dayTempPixel: root.dayCellWidth >= root.dayTextWidth
		? Config.weatherDayTempSize
		: Math.max(8, Math.floor(Config.weatherDayTempSize * (root.dayCellWidth - 2) / root.dayTextWidth))
	readonly property real statsWidth: root.statWidth * 3 + Config.weatherCardGap * 2
	readonly property real placeMaxWidth: root.statsWidth - leftArrow.width - rightArrow.width - addIcon.width - Config.weatherCardHeaderGap * 3
	readonly property real statWidth: (card.width - heroGlyphMetrics.width - Config.weatherCardGap * 4 - heroTempMetrics.width - heroUnitMetrics.width) / 3
	readonly property real dayCardHeight: Config.weatherDayGap * 6 + dayLabelMetrics.height + dayGlyphMetrics.height + dayTempMetrics.height * 3

	contentWidth: Config.weatherCardWidth

	onQueryChanged: {
		root.pickIndex = 0;
		Weather.query(root.query);
	}
	onSuggestionRowsChanged: root.pickIndex = Calc.clamp(root.pickIndex, 0, Math.max(0, root.suggestionRows.length - 1))

	onPlaceNameChanged: {
		root.held = true;
		holdTimer.restart();
	}

	function pickRow(step) {
		const rows = root.suggestionRows;

		if (rows.length === 0)
			return;

		root.pickIndex = Calc.clamp(root.pickIndex + step, 0, rows.length - 1);
	}

	function takeChosen() {
		const rows = root.suggestionRows;

		if (rows.length === 0) {
			root.commitPlace();
			return;
		}

		root.pick(rows[Calc.clamp(root.pickIndex, 0, rows.length - 1)]);
	}

	function startEdit(value, adding) {
		root.editing = true;
		root.adding = adding === true;
		root.query = value !== undefined && value !== "" ? value : "";
		inputBox.setText(root.query, true);
	}

	function stopEdit() {
		root.editing = false;
		root.adding = false;
		root.query = "";
		root.forceActiveFocus();
	}

	function commitPlace() {
		const row = root.match;

		if (row === null || String(row.label || "").trim() === "")
			return;

		const label = String(row.label);
		const adding = root.adding;

		root.stopEdit();

		if (adding)
			Weather.add(label, row.lat, row.lon);
		else
			Weather.choose(label, row.lat, row.lon);
	}

	function pick(row) {
		const label = String(row.label || row.name || "");
		const adding = root.adding;

		root.stopEdit();

		if (label === "")
			return;

		if (adding)
			Weather.add(label, row.lat, row.lon);
		else
			Weather.choose(label, row.lat, row.lon);
	}

	Keys.onPressed: function (event) {
		if (Input.cancel(event)) {
			if (root.editing)
				root.stopEdit();
			else
				root.closeRequested();

			event.accepted = true;
			return;
		}

		if (Input.accept(event) && !root.editing) {
			root.startEdit(root.placeName);
			event.accepted = true;
			return;
		}

		if (root.editing)
			return;

		if (Input.direction(event) === "right") {
			Weather.shift(1);
			event.accepted = true;
		} else if (Input.direction(event) === "left") {
			Weather.shift(-1);
			event.accepted = true;
		}
	}

	TextMetrics {
		id: placeMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherPlaceSize
		text: "Placeholder"
	}

	TextMetrics {
		id: heroGlyphMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroGlyphSize
		text: ""
	}

	TextMetrics {
		id: heroTempMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroTempSize
		text: "-00"
	}

	TextMetrics {
		id: heroUnitMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroUnitSize
		text: "°C"
	}

	TextMetrics {
		id: heroTempInk

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroTempSize
		text: root.tempValue
	}

	TextMetrics {
		id: heroUnitInk

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroUnitSize
		text: String(root.tempUnit).replace("°", "")
	}

	TextMetrics {
		id: heroLabelMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroLabelSize
		text: "FEELS"
	}

	TextMetrics {
		id: heroValueMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherHeroValueSize
		text: "00 km/h"
	}

	TextMetrics {
		id: dayGlyphMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherDayGlyphSize
		text: ""
	}

	TextMetrics {
		id: dayLabelMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherDayLabelSize
		text: "WED"
	}

	TextMetrics {
		id: dayTempMetrics

		font.family: Config.fontFamily
		font.pixelSize: Config.weatherDayTempSize
		text: "100°"
	}

	Column {
		id: card

		width: Config.weatherCardWidth
		spacing: Config.weatherCardGap

		Item {
			id: hero

			width: card.width
			height: tempBox.height

			Icon {
				id: heroGlyph

				anchors.left: parent.left
				anchors.bottom: parent.bottom
				width: heroGlyphMetrics.width
				height: heroGlyphMetrics.height
				size: Config.weatherHeroGlyphSize
				glyph: root.loading ? Config.weatherLoadingIcon : (root.now.icon ? root.now.icon : Config.weatherIcon)
			}

			Item {
				id: tempBox

				anchors.left: heroGlyph.right
				anchors.leftMargin: Config.weatherCardGap
				width: tempNumber.width + tempUnitText.width + 2
				height: tempNumber.height + Config.weatherHeroUnitTop

				Label {
					id: tempNumber

					anchors.left: parent.left
					anchors.bottom: parent.bottom
					height: heroTempMetrics.height
					font.pixelSize: Config.weatherHeroTempSize
					ink: Config.foreground
					text: root.tempValue
				}

				Label {
					id: tempUnitText

					anchors.left: tempNumber.right
					anchors.top: tempNumber.top
					anchors.topMargin: (heroTempInk.tightBoundingRect.y - heroTempInk.boundingRect.y)
						- (heroUnitInk.tightBoundingRect.y - heroUnitInk.boundingRect.y)
					height: heroUnitMetrics.height
					font.pixelSize: Config.weatherHeroUnitSize
					ink: Config.foreground
					text: root.tempUnit
				}
			}

			Item {
				id: stats

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				width: root.statsWidth
				height: header.height + Config.weatherCardHeaderGap + statRow.height

				Item {
					id: header

					width: root.statsWidth
					height: placeMetrics.height

					Label {
						id: placeText

						visible: !root.editing
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						width: Math.min(implicitWidth, root.placeMaxWidth)
						height: placeMetrics.height
						elide: Text.ElideRight
						font.pixelSize: Config.weatherPlaceSize
						ink: placeHit.containsMouse ? Config.foreground : Config.muted
						text: root.placeName

						MouseArea {
							id: placeHit

							anchors.fill: parent
							anchors.margins: -4
							hoverEnabled: true
							onClicked: root.startEdit(root.placeName)
						}
					}

					IconButton {
						id: leftArrow

						visible: !root.editing
						anchors.left: placeText.right
						anchors.leftMargin: Config.weatherCardHeaderGap
						anchors.verticalCenter: parent.verticalCenter
						height: placeMetrics.height
						width: placeMetrics.height
						box: placeMetrics.height
						flat: true
						reveal: true
						shown: root.headerShown
						size: Config.weatherPlaceSize
						inkIdle: Config.dim
						glyph: Config.weatherIconLeft
						onClicked: Weather.shift(-1)
					}

					IconButton {
						id: rightArrow

						visible: !root.editing
						anchors.left: leftArrow.right
						anchors.leftMargin: Config.weatherCardHeaderGap
						anchors.verticalCenter: parent.verticalCenter
						height: placeMetrics.height
						width: placeMetrics.height
						box: placeMetrics.height
						flat: true
						reveal: true
						shown: root.headerShown
						size: Config.weatherPlaceSize
						inkIdle: Config.dim
						glyph: Config.weatherIconRight
						onClicked: Weather.shift(1)
					}

					IconButton {
						id: addIcon

						visible: !root.editing
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						height: placeMetrics.height
						width: placeMetrics.height
						box: placeMetrics.height
						flat: true
						reveal: true
						shown: root.headerShown
						size: Config.weatherPlaceSize
						inkIdle: Config.dim
						glyph: Config.weatherIconAdd
						onClicked: root.startEdit("", true)
					}

					InlineEdit {
						id: inputBox

						visible: root.editing
						editing: root.editing
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						height: placeMetrics.height
						candidate: root.match ? String(root.match.name || "") : ""
						suggestions: root.suggestionRows

						font.pixelSize: Config.weatherPlaceSize

						onEdited: root.query = inputBox.text
						onAccepted: root.takeChosen()
						onCancelled: root.stopEdit()
						onMoved: function (step) { root.pickRow(step); }
						onGhostCompleted: root.query = inputBox.text
					}
				}

				Row {
					id: statRow
					y: header.height + Config.weatherCardHeaderGap


					spacing: Config.weatherCardGap

					Column {
						width: root.statWidth
						spacing: 3

						Label {
							width: parent.width
							height: heroLabelMetrics.height
							font.pixelSize: Config.weatherHeroLabelSize
							ink: Config.muted
							text: "FEELS"
						}

						Label {
							width: parent.width
							height: heroValueMetrics.height
							elide: Text.ElideRight
							font.pixelSize: Config.weatherHeroValueSize
							ink: Config.foreground
							text: root.now.feels ? root.now.feels : "--"
						}
					}

					Column {
						width: root.statWidth
						spacing: 3

						Label {
							width: parent.width
							height: heroLabelMetrics.height
							font.pixelSize: Config.weatherHeroLabelSize
							ink: Config.muted
							text: "WIND"
						}

						Label {
							width: parent.width
							height: heroValueMetrics.height
							elide: Text.ElideRight
							font.pixelSize: Config.weatherHeroValueSize
							ink: Config.foreground
							text: root.now.wind ? root.now.wind : "--"
						}
					}

					Column {
						width: root.statWidth
						spacing: 3

						Label {
							width: parent.width
							height: heroLabelMetrics.height
							font.pixelSize: Config.weatherHeroLabelSize
							ink: Config.muted
							text: "HUMID"
						}

						Label {
							width: parent.width
							height: heroValueMetrics.height
							elide: Text.ElideRight
							font.pixelSize: Config.weatherHeroValueSize
							ink: Config.foreground
							text: root.now.humidity ? root.now.humidity : "--"
						}
					}
				}
			}
		}

		Repeater {
			model: root.editing ? root.suggestionRows : []

			delegate: PanelRow {
				id: suggestRow

				required property var modelData
				required property int index

				width: card.width
				selected: suggestRow.index === root.pickIndex
				title: String(suggestRow.modelData.name || "")
				onHoveredChanged: if (suggestRow.hovered) root.pickIndex = suggestRow.index
				onActivated: root.pick(suggestRow.modelData)

				Label {
					anchors.verticalCenter: parent.verticalCenter
					width: Math.min(implicitWidth, suggestRow.width * 0.4)
					role: "caption"
					text: suggestRow.modelData.region || ""
				}
			}
		}

		Separator {
			id: separator

			width: card.width
			color: Config.rule
		}

		Item {
			id: daysSection

			width: card.width
			height: root.dayCardHeight

			Row {
				id: daysRow

				spacing: Config.weatherDayGap

				Repeater {
					model: root.dayCount

					delegate: Rectangle {
						id: dayCell

						required property int index

						readonly property var row: dayCell.index < root.rows.length ? root.rows[dayCell.index] : null
						readonly property string glyph: dayCell.row ? (dayCell.row.glyph || Config.weatherIcon) : Config.weatherLoadingIcon

						width: root.dayCellWidth
						height: root.dayCardHeight
						radius: Config.appControlRadius
						color: Config.surfaceRaised

						Column {
							width: parent.width
							topPadding: Config.weatherDayGap
							spacing: Config.weatherDayGap

							Label {
								width: parent.width
								height: dayLabelMetrics.height
								horizontalAlignment: Text.AlignHCenter
								font.pixelSize: Config.weatherDayLabelSize
								ink: Config.foreground
								text: dayCell.row ? dayCell.row.day : ""
							}

							TextMetrics {
								id: glyphInk

								font.family: Config.fontFamily
								font.pixelSize: Config.weatherDayGlyphSize
								text: dayCell.glyph
							}

							Item {
								width: parent.width
								height: dayGlyphMetrics.height

								Icon {
									anchors.centerIn: parent
									width: Config.weatherDayGlyphSize
									height: Config.weatherDayGlyphSize
									size: Config.weatherDayGlyphSize
									glyph: dayCell.glyph
								}
							}

							Label {
								width: parent.width
								height: dayTempMetrics.height
								horizontalAlignment: Text.AlignHCenter
								elide: Text.ElideRight
								font.pixelSize: root.dayTempPixel
								ink: Config.foreground
								text: dayCell.row ? dayCell.row.high : ""
							}

							Label {
								width: parent.width
								height: dayTempMetrics.height
								horizontalAlignment: Text.AlignHCenter
								elide: Text.ElideRight
								font.pixelSize: root.dayTempPixel
								ink: Config.muted
								text: dayCell.row ? dayCell.row.low : ""
							}

							Label {
								width: parent.width
								height: dayTempMetrics.height
								horizontalAlignment: Text.AlignHCenter
								elide: Text.ElideRight
								font.pixelSize: root.dayTempPixel
								ink: Config.muted
								text: dayCell.row ? dayCell.row.precip : ""
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
