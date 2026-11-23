import QtQuick
import qs.ui
import qs.panelkit
import qs
import qs.services

PanelPage {
	id: root

	readonly property var media: Yudae.mediaState
	readonly property bool playing: root.media.playing === true
	readonly property string title: root.media.title || ""
	readonly property string artist: root.media.artist || ""
	readonly property string album: root.media.album || ""
	readonly property string art: root.media.art || ""
	readonly property bool known: root.media.known === true
	readonly property bool present: (root.media.name || "") !== ""

	contentWidth: Config.mediaTooltipWidth

	function send(action) {
		Yudae.send({ cmd: { media: action } });
	}

	function togglePlay() {
		root.send("playPause");
	}

	function previous() {
		root.send("previous");
	}

	function next() {
		root.send("next");
	}

	Keys.onPressed: function (event) {
		Input.media(event, root);
	}

	Column {
		id: body

		width: Config.mediaTooltipWidth
		spacing: Config.mediaRowGap

		Item {
			id: artSlot

			width: parent.width
			height: Config.mediaArtHeight

			Item {
				id: art

				anchors.fill: parent
				property string shown: ""

				Rectangle {
					anchors.fill: parent
					color: Config.surfaceRaised
				}

				Icon {
					anchors.centerIn: parent
					visible: art.shown === ""
					size: Math.round(art.height * 0.2)
					ink: Config.muted
					glyph: Config.iconApp
				}

				Image {
					anchors.fill: parent
					cache: false
					sourceSize.width: Config.mediaArtHeight * 2
					fillMode: Image.PreserveAspectCrop
					source: art.shown
				}

				Image {
					id: incoming

					anchors.fill: parent
					cache: false
					sourceSize.width: Config.mediaArtHeight * 2
					fillMode: Image.PreserveAspectCrop
					source: root.art
					opacity: 0

					onStatusChanged: {
						if (status !== Image.Ready) {
							fade.stop();
							opacity = 0;
						}

						if (root.art === "")
							art.shown = "";
						else if (status === Image.Ready)
							fade.restart();
					}

					onOpacityChanged: if (opacity >= 1 && status === Image.Ready)
						art.shown = String(source);

					NumberAnimation {
						id: fade

						target: incoming
						property: "opacity"
						from: 0
						to: 1
						duration: Config.popupFadeMs
						easing.type: Easing.OutCubic
					}
				}
			}

			Rectangle {
				anchors.fill: parent
				color: "transparent"
				border.width: Config.popupBorderWidth
				border.color: Config.rule
			}
		}

		Column {
			width: parent.width
			spacing: Config.mediaLineGap

			Label {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				font.pixelSize: Config.mediaTitleSize
				ink: root.present ? Config.foreground : Config.muted
				text: root.title !== "" ? root.title : Config.mediaEmpty
			}

			Label {
				width: parent.width
				visible: root.artist !== "" || root.album !== ""
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				ink: Config.foreground
				text: [root.artist, root.album].filter(s => s !== "").join(" - ")
			}
		}

		Item {
			id: times

			width: parent.width
			height: elapsed.implicitHeight
			visible: root.known

			Label {
				id: elapsed

				anchors.left: parent.left

				ink: Config.foreground
				text: root.media.elapsed || ""
			}

			Label {
				anchors.right: parent.right

				ink: Config.muted
				text: root.media.total || ""
			}
		}

		StepBar {
			width: parent.width
			visible: root.known
			level: (root.media.percent || 0) / 100
		}

		Item {
			id: controls

			width: parent.width
			height: Config.mediaButtonGlyphSize
			visible: root.present

			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: Config.mediaButtonGap

				IconButton {
					box: Config.mediaButtonGlyphSize
					size: Config.mediaButtonGlyphSize
					flat: true
					hitMargin: Config.barHitPadding
					inkIdle: Config.foreground
					glyph: Config.iconPrev
					label: "Previous"
					onClicked: root.previous()
				}

				IconButton {
					box: Config.mediaButtonGlyphSize
					size: Config.mediaButtonGlyphSize
					flat: true
					hitMargin: Config.barHitPadding
					inkIdle: Config.foreground
					glyph: root.playing ? Config.iconPause : Config.iconPlay
					label: "Play"
					onClicked: root.togglePlay()
				}

				IconButton {
					box: Config.mediaButtonGlyphSize
					size: Config.mediaButtonGlyphSize
					flat: true
					hitMargin: Config.barHitPadding
					inkIdle: Config.foreground
					glyph: Config.iconNext
					label: "Next"
					onClicked: root.next()
				}
			}
		}
	}
}
