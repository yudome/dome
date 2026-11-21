pragma ComponentBehavior: Bound

import QtQuick
import qs
import qs.ui
import qs.services

Column {
	id: root

	readonly property var monitor: Yudae.screenActive
	readonly property bool ready: root.monitor !== null && root.monitor !== undefined
	readonly property var groups: (Yudae.screenPanel.groups || []).filter(function (g) { return g.kind !== "font" && g.visible !== false; })
	readonly property var resolutions: root.ready ? root.monitor.resolutions || [] : []
	readonly property bool more: root.resolutions.length > 8
	property bool open: false

	spacing: Config.settingsSectionGap

	function density(c, r, n) {
		const ramp = " .-+xXS#";
		const k = Math.floor((c + 0.5) / n * (ramp.length - 1) - (r === 1 ? 1.2 : 0) + Calc.hash(c, r, 0) * 0.8);
		return ramp[Calc.clamp(k, 1, ramp.length - 1)];
	}

	function wave(c, r, n, t, value, options) {
		const ramp = " .-+xXS#";
		const top = Math.max.apply(null, options.map(Number));
		const rank = top > 0 ? Number(value) / top : 0;
		const gap = Math.round(18 - rank * 10);
		const head = Math.floor(t * (6 + rank * 30));
		const behind = (((head - c - r) % gap) + gap) % gap;
		return ramp[Math.max(0, ramp.length - 1 - behind)];
	}

	function format(kind, value) {
		if (kind === "scale" && value !== "" && isFinite(Number(value)))
			return Number(value).toFixed(2);
		if (kind === "refresh" && value !== "" && value.indexOf("Hz") < 0)
			return value + " Hz";
		return value;
	}

	component Heading: Text {
		width: parent ? parent.width : 0
		elide: Text.ElideRight
		font.family: Config.fontFamily
		font.pixelSize: Config.settingsFontSize + 3
		color: Config.foreground
	}

	component Panel: Rectangle {
		default property alias rows: inner.data

		width: parent ? parent.width : 0
		height: inner.height
		radius: Config.settingsRadius
		color: Config.settingsCard

		Column {
			id: inner

			x: Config.settingsGap + 4
			width: parent.width - x * 2
		}
	}

	component Rule: Rectangle {
		width: parent ? parent.width : 0
		height: 1
		color: Config.settingsRule
	}

	Column {
		width: root.width
		spacing: 12

		Heading {
			text: "Monitor"
		}

		Panel {
			Item {
				width: parent.width
				height: Config.settingsRowHeight + 16

				Column {
					anchors.left: parent.left
					anchors.right: detect.left
					anchors.rightMargin: Config.settingsGap
					anchors.verticalCenter: parent.verticalCenter
					spacing: 3

					Text {
						width: parent.width
						elide: Text.ElideRight
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsFontSize + 1
						color: Config.foreground
						text: root.ready ? (root.monitor.name || "") + (root.monitor.description ? "  " + root.monitor.description : "") : Config.displayNothing
					}

					Text {
						width: parent.width
						visible: root.ready
						elide: Text.ElideRight
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsSmallSize
						color: Config.settingsLabel
						text: root.ready ? root.monitor.width + "x" + root.monitor.height + "  " + Math.round(root.monitor.refresh) + " Hz" : ""
					}
				}

				ArrowPill {
					id: detect

					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					glyph: Config.iconRefresh
					label: "Detect"
					onClicked: Yudae.cmd("screen", { detect: true })
				}
			}

			Repeater {
				model: root.groups

				delegate: Column {
					id: group

					required property var modelData

					width: parent.width

					Rule {}

					Item {
						width: parent.width
						height: Math.max(Config.settingsRowHeight, bar.implicitHeight + 16)

						Text {
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							font.family: Config.fontFamily
							font.pixelSize: Config.settingsFontSize + 1
							color: Config.foreground
							text: group.modelData.label
						}

						GlyphBar {
							id: bar

							anchors.right: value.left
							anchors.rightMargin: 12
							anchors.verticalCenter: parent.verticalCenter
							width: Math.min(Config.settingsControlWidth, parent.width * 0.5) - value.width - 12
							model: group.modelData.options
							selected: group.modelData.selected
							ink: Config.settingsInk
							glyph: group.modelData.kind === "refresh" ? root.wave : root.density
							animated: group.modelData.kind === "refresh"
							follow: true
							onPick: function (next) { Yudae.cmd("screen", { pick: { kind: group.modelData.kind, value: next } }); }
						}

						Text {
							id: value

							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							width: 56
							horizontalAlignment: Text.AlignRight
							font.family: Config.fontFamily
							font.pixelSize: Config.settingsFontSize
							font.features: { "tnum": 1 }
							color: Config.foreground
							text: root.format(group.modelData.kind, bar.hoverLabel !== "" ? bar.hoverLabel : group.modelData.shown)
						}
					}
				}
			}
		}
	}

	Column {
		width: root.width
		spacing: 12
		visible: root.resolutions.length > 0

		Heading {
			text: "Resolution"
		}

		Panel {
			Repeater {
				model: root.open ? root.resolutions : root.resolutions.slice(0, 8)

				delegate: Item {
					id: mode

					required property var modelData
					required property int index

					readonly property bool current: root.ready && mode.modelData.width === root.monitor.width && mode.modelData.height === root.monitor.height

					width: parent.width
					height: Config.settingsRowHeight - 6

					Rule {
						visible: mode.index > 0
					}

					Text {
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsFontSize + 1
						font.features: { "tnum": 1 }
						color: mode.current || modeHover.containsMouse ? Config.foreground : Config.settingsLabel
						text: mode.modelData.label
					}

					Text {
						anchors.right: check.left
						anchors.rightMargin: 12
						anchors.verticalCenter: parent.verticalCenter
						font.family: Config.fontFamily
						font.pixelSize: Config.settingsSmallSize
						font.features: { "tnum": 1 }
						color: Config.settingsLabel
						text: mode.modelData.maxRefresh > 0 ? mode.modelData.maxRefresh + " Hz" : ""
					}

					Glyph {
						id: check

						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						width: 16
						height: 16
						size: Config.settingsFontSize
						color: Config.foreground
						glyph: mode.current ? Config.launcherIconActive : ""
					}

					MouseArea {
						id: modeHover

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: Yudae.cmd("screen", { pick: { kind: "resolution", value: mode.modelData.label } })
					}
				}
			}

			Item {
				width: parent.width
				height: root.more ? Config.settingsRowHeight - 6 : 0
				visible: root.more

				Text {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					font.family: Config.fontFamily
					font.pixelSize: Config.settingsFontSize + 1
					color: moreHover.containsMouse ? Config.foreground : Config.settingsLabel
					text: root.open ? "Fewer resolutions" : root.resolutions.length - 8 + " more resolutions"
				}

				MouseArea {
					id: moreHover

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.open = !root.open
				}
			}
		}
	}
}
