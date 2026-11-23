pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs
import qs.services

Item {
	id: store

	visible: false

	property var schema: ({ apply: "instant", pages: [] })
	property string page: ""
	property var history: []
	property string query: ""
	property string widgetGroup: "All"
	property var layoutDoc: null
	property var pending: ({})
	property var pendingLayout: null
	property var expect: ({})
	property int writes: 0
	property var features: ({})
	property string failed: ""
	property bool loaded: false

	readonly property bool manual: store.schema.apply === "manual"
	readonly property var pages: store.schema.pages || []
	readonly property var current: store.pages.find(function (p) { return p.name === store.page; }) || store.pages[0] || ({ name: "", sections: [] })
	readonly property var layout: store.pendingLayout || store.layoutDoc
	readonly property bool dirty: Object.keys(store.pending).length > 0 || store.pendingLayout !== null
	readonly property bool barShown: store.manual && (store.dirty || store.failed !== "")
	readonly property bool searching: store.query.trim() !== ""
	readonly property bool hasBar: store.current.sections.some(function (s) { return s.name === "bar"; })
	readonly property var library: Object.keys(store.features).sort().map(function (id) { return store.features[id]; })
	readonly property var widgetGroups: [
		{ label: "All", value: "All", sections: [] },
		{ label: "System", value: "System", sections: ["cpu", "memory"] },
		{ label: "Sound", value: "Sound", sections: ["mixer", "media"] },
		{ label: "Network", value: "Network", sections: ["network", "weather"] },
		{ label: "Time", value: "Time", sections: ["calendar", "contrib"] },
		{ label: "Agent", value: "Agent", sections: ["agent"] },
		{ label: "Storage", value: "Storage", sections: ["disk"] }
	]
	readonly property var pageSections: {
		const sections = store.current.sections || [];
		if (store.current.name !== "Widgets" || store.widgetGroup === "All")
			return sections;
		const group = store.widgetGroups.find(function (g) { return g.value === store.widgetGroup; });
		if (!group)
			return sections;
		return sections.filter(function (section) { return group.sections.indexOf(section.name) >= 0; });
	}
	readonly property var found: {
		const q = store.query.trim().toLowerCase();
		if (q === "")
			return [];
		const out = [];
		store.pages.forEach(function (p) {
			p.sections.forEach(function (s) {
				const whole = s.title.toLowerCase().indexOf(q) >= 0 || p.name.toLowerCase().indexOf(q) >= 0;
				const keys = whole ? s.keys : s.keys.filter(function (k) {
					return k.label.toLowerCase().indexOf(q) >= 0 || k.key.toLowerCase().indexOf(q) >= 0;
				});
				if (keys.length > 0)
					out.push({ name: s.name, title: s.title, keys: keys });
			});
		});
		return out;
	}
	readonly property var monitor: Yudae.screenActive || null
	readonly property var screenGroups: (Yudae.screenPanel.groups || []).filter(function (g) { return g.kind !== "font" && g.visible !== false; })
	readonly property var wallpapers: Yudae.wallpaper.list || []
	readonly property string wallpaper: Yudae.wallpaper.active || ""
	readonly property string status: store.pages.length === 0 ? (Yudae.connected && !store.loaded ? "loading" : "error") : store.searching && store.found.length === 0 ? "empty" : "ready"

	Binding {
		target: Config
		property: "overlay"
		value: store.manual ? store.pending : ({})
	}

	function load() {
		Yudae.request("settings", "schema", {}, function (result) {
			store.loaded = true;
			if (result && result.pages)
				store.schema = store.withExpect(result);
			if (store.page === "" && store.pages.length > 0) {
				const wanted = (Quickshell.env("YUDAE_PANE") || "").toLowerCase();
				const hit = store.pages.find(function (p) { return p.name.toLowerCase() === wanted || p.name.toLowerCase().indexOf(wanted) === 0 && wanted !== ""; });
				store.page = hit ? hit.name : store.pages[0].name;
			}
		});
	}

	function go(name) {
		if (name === store.page && !store.searching)
			return;
		store.history = store.history.concat([store.page]);
		store.page = name;
		store.query = "";
	}

	function back() {
		if (store.history.length === 0)
			return;
		store.page = store.history[store.history.length - 1];
		store.history = store.history.slice(0, -1);
	}

	function value(key, fallback) {
		return store.pending[key] !== undefined ? store.pending[key] : fallback;
	}

	function send(key, next) {
		store.writes += 1;
		Yudae.request("settings", "set", { key: key, value: next }, function (result) {
			store.failed = result === null ? key : "";
			store.writes = Math.max(0, store.writes - 1);
			store.load();
			if (store.writes === 0)
				store.expect = ({});
		});
	}

	function mapKeys(next, values) {
		return {
			apply: next.apply,
			pages: next.pages.map(function (page) {
				return {
					name: page.name,
					glyph: page.glyph,
					sections: page.sections.map(function (section) {
						return {
							name: section.name,
							title: section.title,
							keys: section.keys.map(function (key) {
								return values[key.key] === undefined ? key : Object.assign({}, key, { value: values[key.key] });
							})
						};
					})
				};
			})
		};
	}

	function withExpect(next) {
		return Object.keys(store.expect).length === 0 ? next : store.mapKeys(next, store.expect);
	}

	function original(key) {
		for (let p = 0; p < store.pages.length; p++) {
			const sections = store.pages[p].sections;
			for (let s = 0; s < sections.length; s++) {
				const keys = sections[s].keys;
				for (let k = 0; k < keys.length; k++) {
					if (keys[k].key === key)
						return keys[k].value;
				}
			}
		}
		return undefined;
	}

	function setValue(key, next) {
		const unchanged = next === store.original(key);
		if (!store.manual || key === "settingsApply") {
			if (!unchanged)
				store.send(key, next);
			return;
		}
		const out = Object.assign({}, store.pending);
		if (unchanged)
			delete out[key];
		else
			out[key] = next;
		store.pending = out;
	}

	function writeLayout(next) {
		store.layoutDoc = next;
		Yudae.request("bar", "layout", { layout: next }, function (result) {
			if (result === null)
				store.failed = "layout";
		});
	}

	function setLayout(next) {
		if (!store.manual) {
			store.writeLayout(next);
			return;
		}
		store.pendingLayout = JSON.stringify(next) === JSON.stringify(store.layoutDoc) ? null : next;
	}

	function apply() {
		store.failed = "";
		store.expect = Object.assign({}, store.expect, store.pending);
		store.schema = store.mapKeys(store.schema, store.pending);
		Object.keys(store.pending).forEach(function (key) { store.send(key, store.pending[key]); });
		if (store.pendingLayout !== null)
			store.writeLayout(store.pendingLayout);
		store.pending = {};
		store.pendingLayout = null;
	}

	function revert() {
		store.pending = {};
		store.pendingLayout = null;
		store.expect = ({});
		store.failed = "";
	}

	function pickScreen(kind, value) {
		Yudae.cmd("screen", { pick: { kind: kind, value: value } });
	}

	function detectScreen() {
		Yudae.cmd("screen", { detect: true });
	}

	function pickWallpaper(path) {
		Yudae.cmd("wallpaper", { apply: { path: path } });
	}

	Connections {
		target: Yudae

		function onConnectedChanged() {
			if (Yudae.connected)
				store.load();
		}

		function onSettingsChanged() {
			reloadTimer.restart();
		}
	}

	Timer {
		id: reloadTimer

		interval: Config.popupFadeMs
		onTriggered: store.load()
	}

	Component.onCompleted: if (Yudae.connected) store.load()

	FileView {
		path: Quickshell.shellDir + "/topbarlayout.json"
		watchChanges: true
		printErrors: false

		onFileChanged: this.reload()
		onLoaded: {
			try {
				store.layoutDoc = JSON.parse(this.text());
			} catch (error) {
				store.layoutDoc = { version: 1, bar: { layout: { left: [], center: [], right: [] } } };
			}
		}
	}

	FolderListModel {
		id: featureDirs

		folder: "file://" + Quickshell.shellDir + "/features"
		showDirs: true
		showFiles: false
	}

	Instantiator {
		model: featureDirs

		delegate: FileView {
			required property string filePath

			path: filePath + "/feature.json"
			printErrors: false

			onLoaded: {
				let info = null;
				try {
					info = JSON.parse(this.text());
				} catch (error) {
					return;
				}
				if (!info.widget || !info.name)
					return;
				const out = Object.assign({}, store.features);
				out[info.name] = { id: info.name, glyph: info.glyph || "", description: info.description || "" };
				store.features = out;
			}
		}
	}
}
