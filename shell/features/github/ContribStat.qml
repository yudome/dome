import QtQuick
import qs.ui
import qs.services
import qs

BarStat {
	id: root

	icon: Config.iconGithub
	dim: Github.login === ""

	popupContent: Component {
		GithubGrid {
			onCloseRequested: root.closePopup()
			onRefreshRequested: Github.refresh(true)
		}
	}
}
