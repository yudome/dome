import QtQuick
import Quickshell.Services.Pam
import qs

Item {
	id: root

	property string pending: ""

	signal accepted()
	signal rejected(string text)

	function check(user, password) {
		root.pending = password;
		if (!pam.start()) {
			root.pending = "";
			root.rejected(Config.lockPamError);
		}
	}

	PamContext {
		id: pam

		config: Config.lockPamService
		configDirectory: Qt.resolvedUrl("pam.d")

		onResponseRequiredChanged: {
			if (!pam.responseRequired)
				return;

			const value = root.pending;

			root.pending = "";
			pam.respond(value);
		}

		onCompleted: function (result) {
			pam.active = false;
			root.pending = "";

			if (result === PamResult.Success)
				root.accepted();
			else
				root.rejected(Config.lockWrongText);
		}

		onError: function (error) {
			pam.active = false;
			root.pending = "";
			root.rejected(PamError.toString(error));
		}
	}
}
