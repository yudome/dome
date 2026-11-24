import QtQuick
import qs.ui
import qs
import qs.services

BarStat {
	id: root

	inkId: "weather"

	iconSize: Config.iconSize + 4
	iconLift: -2.5 + (root.glyphInkHeight - Config.iconSize) / 5
	icon: Weather.current.code >= 0 ? Weather.current.icon : Config.weatherLoadingIcon

	popupContent: Component {
		WeatherCard {
			onCloseRequested: root.closePopup()
		}
	}
}
