import QtQuick
import qs
import qs.ui
import qs.panelkit
import qs.services

PanelRow {
	id: row

	required property var modelData

	property string pendingSsid: ""
	property string targetSsid: ""

	readonly property bool pending: row.pendingSsid === row.modelData.ssid

	selected: row.targetSsid === row.modelData.ssid
	current: row.modelData.inUse === true
	glyph: Config.wifiGlyph(row.modelData.bars)
	title: row.modelData.ssid

	Label {
		visible: row.pending
		ink: row.ink
		text: Config.networkWifiConnecting
	}

	Glyph {
		visible: !row.pending && row.modelData.locked === true
		width: row.leadingWidth
		height: row.leadingWidth
		size: Config.fontSize
		color: row.ink
		glyph: Config.iconLock
	}
}
