import QtQuick
import qs
import qs.services
import qs.appkit

QtObject {
	id: store

	property string tab: "map"
	property var packageRows: []
	property var cacheRows: []
	property bool packagesLoaded: false
	property bool cachesLoaded: false
	property var mapSelection: ({})
	property var packageSelection: ({})
	property var cacheSelection: ({})

	readonly property var disk: Yudae.diskState || ({})
	readonly property var view: store.disk.view || null
	readonly property var entries: store.view && store.view.children ? store.view.children : []
	readonly property string root: store.disk.root || "/"
	readonly property string path: store.disk.focus || store.root
	readonly property bool scanning: store.disk.status === "scanning"
	readonly property real usedRatio: (store.disk.deviceTotal || 0) > 0 ? Math.min(1, (store.disk.used || 0) / store.disk.deviceTotal) : 0
	readonly property string usage: store.formatSize(store.disk.used || 0) + " used  " + store.formatSize(store.disk.free || 0) + " free"
	readonly property string mapStatus: !Yudae.connected ? "error" : store.scanning && store.entries.length === 0 ? "loading" : store.entries.length === 0 ? "empty" : "ready"
	readonly property string mapEmpty: store.view ? "Empty folder" : "No map"
	readonly property string mapHint: store.view ? "" : Config.diskScanHint
	readonly property var crumbs: {
		const parts = store.path.split("/").filter(function (p) { return p !== ""; });
		const out = [{ label: "/", value: "/" }];
		let path = "";
		parts.forEach(function (p) {
			path += "/" + p;
			out.push({ label: p, value: path });
		});
		return out;
	}
	readonly property var packageItems: store.packageRows.map(function (r) {
		return { key: r.name, name: r.name, detail: r.version + "  " + r.repo + (r.orphan ? "  orphan" : ""), size: r.size, sizeText: r.sizeText, raw: r };
	})
	readonly property var cacheItems: store.cacheRows.map(function (r) {
		return { key: r.id, name: r.label, detail: r.path, size: r.size, sizeText: r.sizeText, raw: r };
	})
	readonly property var selectedRows: {
		const tag = function (rows, group) {
			return rows.map(function (r) { return Object.assign({ group: group }, r); });
		};
		return tag(Object.values(store.mapSelection), "Files").concat(tag(Object.values(store.packageSelection), "Packages"), tag(Object.values(store.cacheSelection), "Caches"));
	}
	readonly property real selectedTotal: store.sumSizes(store.selectedRows)

	property AppTask job: AppTask {}

	property AppAction scanAction: AppAction {
		text: "Scan"
		icon: "refresh"
		busy: store.scanning
		onTriggered: store.scan()
	}

	property AppAction cleanAction: AppAction {
		text: "Clean"
		icon: "remove"
		kind: "danger"
		confirm: true
		enabled: store.selectedRows.length > 0 && !store.job.running
		busy: store.job.running
		onTriggered: store.clean()
	}

	function formatSize(bytes) {
		const value = Number(bytes) || 0;
		const units = [["TB", 1099511627776], ["GB", 1073741824], ["MB", 1048576], ["kB", 1024]];
		for (let i = 0; i < units.length; i++) {
			if (value >= units[i][1])
				return (value / units[i][1]).toFixed(1) + " " + units[i][0];
		}
		return value + " B";
	}

	function rowsOf(list) {
		return list.map(function (entry) {
			return {
				name: entry.name || "",
				version: entry.version || "",
				size: entry.size || 0,
				sizeText: store.formatSize(entry.size || 0),
				repo: entry.repo || entry.origin || "",
				orphan: entry.orphan === true,
				flatpak: entry.repo === undefined
			};
		});
	}

	function glyphOf(row) {
		return row.group === "Packages" ? "package" : row.group === "Caches" ? "cache" : row.kind === "dir" ? "folder" : "file";
	}

	function scan() {
		store.mapSelection = ({});
		Yudae.diskCommand("scan", { path: store.root });
	}

	function openPath(path) {
		Yudae.diskCommand("view", { path: path });
	}

	function selectTab(name) {
		store.tab = name;
		if (name === "packages" && !store.packagesLoaded)
			store.loadPackages();
		if (name === "caches" && !store.cachesLoaded)
			store.loadCaches();
	}

	function loadPackages() {
		Yudae.diskCommand("packages", {}, function (result) {
			store.packagesLoaded = true;
			if (result)
				store.packageRows = store.rowsOf(result.list || []).concat(store.rowsOf(result.flatpak || []));
		});
	}

	function loadCaches() {
		Yudae.diskCommand("caches", {}, function (result) {
			store.cachesLoaded = true;
			if (!result)
				return;
			store.cacheRows = (result.list || []).map(function (entry) {
				return {
					id: entry.id || "",
					label: entry.label || "",
					path: entry.path || "",
					tool: entry.tool || "",
					size: entry.size || 0,
					sizeText: store.formatSize(entry.size || 0),
					root: entry.root === true,
					exists: entry.exists === true
				};
			});
		});
	}

	function toggled(map, key, row) {
		const next = Object.assign({}, map);
		if (next[key])
			delete next[key];
		else
			next[key] = row;
		return next;
	}

	function toggleMapItem(item) {
		store.mapSelection = store.toggled(store.mapSelection, item.path, item);
	}

	function togglePackage(row) {
		store.packageSelection = store.toggled(store.packageSelection, row.name, row);
	}

	function toggleCache(row) {
		store.cacheSelection = store.toggled(store.cacheSelection, row.id, row);
	}

	function sumSizes(rows) {
		return rows.reduce(function (size, r) { return size + (Number(r.size) || 0); }, 0);
	}

	function unselect(row) {
		const drop = function (map, key) {
			const next = Object.assign({}, map);
			delete next[key];
			return next;
		};
		if (row.group === "Packages")
			store.packageSelection = drop(store.packageSelection, row.name);
		else if (row.group === "Caches")
			store.cacheSelection = drop(store.cacheSelection, row.id);
		else
			store.mapSelection = drop(store.mapSelection, row.path);
	}

	function clean() {
		const tasks = [];
		Object.values(store.mapSelection).forEach(function (item) {
			tasks.push({ label: item.name, run: function (done) { Yudae.diskCommand("delete", { path: item.path }, done); } });
		});
		Object.values(store.cacheSelection).forEach(function (row) {
			tasks.push({ label: row.label || row.id, run: function (done) { Yudae.diskCommand("clean", { id: row.id, confirm: true }, done); } });
		});
		const names = Object.values(store.packageSelection).map(function (r) { return r.name; });
		if (names.length > 0)
			tasks.push({ label: "Packages", run: function (done) { Yudae.diskCommand("uninstall", { names: names, confirm: true }, done); } });
		if (tasks.length === 0)
			return;
		store.job.start(tasks.length);
		store.step(tasks, 0);
	}

	function step(tasks, index) {
		if (index >= tasks.length) {
			store.mapSelection = ({});
			store.packageSelection = ({});
			store.cacheSelection = ({});
			Yudae.diskCommand("view", { path: store.path });
			store.loadPackages();
			store.loadCaches();
			store.jobTimer.restart();
			return;
		}
		store.job.label = tasks[index].label;
		tasks[index].run(function (result) {
			const bad = !result || result.ok === false || (result.error && result.error.length > 0);
			store.job.step(tasks[index].label, !bad);
			store.step(tasks, index + 1);
		});
	}

	property Timer jobTimer: Timer {
		interval: Config.confirmMs
		onTriggered: store.job.reset()
	}

	Component.onCompleted: {
		store.loadPackages();
		store.loadCaches();
	}
}
