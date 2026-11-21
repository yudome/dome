import QtQuick
import qs
import qs.services
import qs.ui

Item {
	id: root

	property string widgetId: ""
	property var templates: null
	property real slot: 22
	property color ink: Config.foreground

	readonly property var net: Yudae.network || ({})
	readonly property var audio: Yudae.audio || ({})
	readonly property var battery: (Yudae.system.battery && Yudae.system.battery.present) ? Yudae.system.battery : null
	readonly property var demo: ({ present: true, pct: 72, charging: false })

	width: root.slot
	height: root.slot

	function volume() {
		const list = root.audio.nodes || [];
		for (let i = 0; i < list.length; i++) {
			if (list[i].id === root.audio.sink)
				return list[i].volume;
		}
		return 0;
	}

	function batteryGlyph() {
		const b = root.battery || (Config.powerDemo ? root.demo : null);
		if (!b)
			return Config.iconPowerPlug;
		if (b.charging)
			return Config.iconBatteryCharge;
		if (b.pct >= 95)
			return Config.iconBatteryFull;
		if (b.pct >= 60)
			return Config.iconBatteryHigh;
		if (b.pct >= 30)
			return Config.iconBatteryMid;
		if (b.pct >= 10)
			return Config.iconBatteryLow;
		return Config.iconBatteryAlert;
	}

	function glyph() {
		const pct = root.volume() * 100;
		switch (root.widgetId) {
		case "workspaces": return "";
		case "clock": return Config.glyph("day");
		case "notify": return Config.glyph("bell");
		case "cpu": return Config.glyph("cpu");
		case "memory": return Config.glyph("memory");
		case "media": return Config.iconApp;
		case "network": return root.net.kind === "wifi" ? Config.wifiGlyph(root.net.bars) : (!root.net.connected && root.net.hasWifi === true ? Config.iconWifiOff : Config.iconEthernet);
		case "volume": return pct >= 67 ? Config.iconVolumeHigh : pct >= 34 ? Config.iconVolumeMid : Config.iconVolumeLow;
		case "weather": return Weather.current.code >= 0 ? Weather.current.icon : Config.weatherIcon;
		case "power": return root.batteryGlyph();
		case "github": return Config.glyph("github");
		case "tray": return Config.iconChevron;
		case "spacer": return Config.glyph("spacer");
		default: return "";
		}
	}

	WidgetIcon {
		visible: root.widgetId === "agent" || root.widgetId === "workspaces"
		source: root.templates ? root.templates.componentFor(root.widgetId) : null
		slot: root.slot
	}

	Glyph {
		visible: root.widgetId !== "agent" && root.widgetId !== "workspaces"
		anchors.centerIn: parent
		width: root.slot
		height: root.slot
		size: Config.settingsFontSize + 2
		color: root.ink
		glyph: root.widgetId === "agent" ? "" : root.glyph()
	}
}
