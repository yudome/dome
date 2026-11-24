import QtQuick
import Quickshell
import qs
import qs.services

QtObject {
	id: store

	readonly property var vms: Yudae.vms.list || []
	readonly property string runs: Quickshell.env("YUDAE_VM_ROOT") || Quickshell.shellDir + "/../vm/runs"

	property string selectedName: ""
	property string live: Quickshell.env("YUDAE_VM") || ""

	readonly property string selected: store.live.length > 0 ? store.live : (store.selectedName.length > 0 ? store.selectedName : (Yudae.vms.selected || (store.vms.length > 0 ? store.vms[0].name : "")))
	readonly property var current: store.vms.find(function (vm) { return vm.name === store.selected; }) || ({})
	readonly property string tier: store.current.tier || "off"
	readonly property bool running: store.tier !== "off"
	readonly property bool awake: store.tier === "hot"
	readonly property string status: !Yudae.connected ? "error" : store.vms.length === 0 ? "empty" : "ready"
	readonly property string summary: store.current.name !== undefined ? (store.current.cores || 0) + " cores  " + (store.current.memMb || 0) + " MB" : ""
	readonly property string displayQmp: store.current.backend === "gl" ? store.runs + "/" + store.live + "/display.qmp" : ""
	readonly property string displayBroker: store.current.backend === "nvidia" ? store.runs + "/" + store.live + "/display-nvidia.sock" : ""
	readonly property var powerEntries: {
		const list = [];
		if (store.awake)
			list.push({ label: "Sleep", icon: "moon", action: "sleep" });
		else if (store.running)
			list.push({ label: "Wake", icon: "sun", action: "wake" });
		else
			list.push({ label: "Start", icon: "play", action: "start" });
		list.push({ label: "Stop", icon: "powerOff", action: "stop", enabled: store.running });
		list.push({ label: "Destroy", confirmLabel: Config.vmDestroyConfirm, hint: Config.vmDestroyHint, icon: "close", action: "destroy", danger: true, confirm: true });
		return list;
	}
	readonly property var hardware: [
		{ label: "Cores", key: "cores", value: store.current.cores || 1, min: 1, max: 32, step: 1, suffix: "" },
		{ label: "Memory", key: "mem", value: store.current.memMb || 512, min: 512, max: 65536, step: 512, suffix: "MB" }
	]

	function providerIcon(vm) {
		return (vm.harness || "") !== "" ? "file://" + Quickshell.shellDir + "/assets/providers/" + vm.harness + ".svg?v=4" : "";
	}

	function sessionLabel(vm) {
		const title = vm.sessionTitle || vm.session || "";
		if (title.length > 0)
			return title;
		return (vm.harness || "").length > 0 ? "no session" : "no agent";
	}

	function select(name) {
		store.selectedName = name;
		Yudae.vmsCommand("select", { name: name });
	}

	function take(name) {
		store.select(name);
		store.live = name;
		Yudae.vmsCommand("view", { name: name });
	}

	function release(name) {
		Yudae.vmsCommand("release", { name: name });
		if (store.live === name)
			store.live = "";
	}

	function power(action) {
		store.live = "";
		Yudae.vmsCommand(action, { name: store.selected });
		if (action === "destroy")
			store.selectedName = "";
	}

	function configure(key, value) {
		if (store.selected.length === 0)
			return;
		const args = { name: store.selected };
		args[key] = value;
		Yudae.vmsCommand("config", args);
	}

	function releaseOnClose() {
		if (store.live.length > 0)
			Quickshell.execDetached([Quickshell.shellDir + "/../scripts/yudae", "vm", "release", store.live]);
	}
}
