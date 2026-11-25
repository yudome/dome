pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.appkit
import qs.services

AppSection {
	id: root

	required property var store

	readonly property var strip: root.store.stillStrip
	readonly property var frames: root.strip ? root.strip.frames : []
	readonly property real duration: root.strip ? root.strip.duration : 0
	property int scrub: -1

	function at(x) {
		return root.duration * Math.max(0, Math.min(1, x / film.width));
	}

	function nearest(t) {
		let best = -1;
		for (let i = 0; i < root.frames.length; i++) {
			if (best < 0 || Math.abs(root.frames[i].t - t) < Math.abs(root.frames[best].t - t))
				best = i;
		}
		return best;
	}

	title: Config.wallpaperStillTitle
	focus: visible

	Keys.onLeftPressed: root.store.stepStill(-1)
	Keys.onRightPressed: root.store.stepStill(1)
	Keys.onReturnPressed: root.store.saveStill()
	Keys.onEnterPressed: root.store.saveStill()

	Column {
		width: parent.width
		spacing: Metrics.gap

		Image {
			width: parent.width
			height: Math.round(width * 9 / 16)
			fillMode: Image.PreserveAspectFit
			asynchronous: true
			cache: false
			source: root.scrub >= 0 && root.frames[root.scrub] ? "file://" + root.frames[root.scrub].thumb : root.store.stillPreview !== "" ? "file://" + root.store.stillPreview : ""
		}

		Item {
			id: film

			width: parent.width
			height: Math.round(width / Math.max(1, root.frames.length) * 9 / 16)
			clip: true

			Row {
				Repeater {
					model: root.frames

					delegate: Image {
						required property var modelData
						required property int index

						width: film.width / Math.max(1, root.frames.length)
						height: film.height
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						source: "file://" + modelData.thumb
						opacity: index === root.scrub ? 1 : Metrics.disabled
					}
				}
			}

			Rectangle {
				x: root.duration > 0 ? Math.round(film.width * Math.max(0, root.store.stillT) / root.duration - width / 2) : 0
				width: Metrics.border * 2
				height: film.height
				color: AppPalette.ink
				visible: root.store.stillT >= 0
			}

			MouseArea {
				anchors.fill: parent

				onPressed: function (mouse) {
					root.forceActiveFocus();
					root.scrub = root.nearest(root.at(mouse.x));
				}
				onPositionChanged: function (mouse) {
					root.scrub = root.nearest(root.at(mouse.x));
				}
				onReleased: function (mouse) {
					root.scrub = -1;
					root.store.previewStill(root.at(mouse.x));
				}
			}
		}

		Row {
			spacing: Metrics.gap

			Hint {
				line: Config.wallpaperStillStepHint
			}

			Hint {
				glyph: "enter"
				text: Config.wallpaperStillSaveHint
			}
		}
	}
}
