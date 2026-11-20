.pragma library

var enums = {
	barStatMode: ["icon", "text"],
	popupPos: ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"],
	launcherMove: ["remember", "forget"],
	weatherTempUnit: ["fahrenheit", "celsius"]
};

var primary = [
	"fontFamily", "clockFormat", "lockClockFormat", "weatherLocation", "launcherClipTimeFormat",
	"fontSize", "iconSize", "spacing", "gapsIn", "gapsOut", "workspaceSpacing",
	"barCells", "barPadding", "barInset", "barStatSpacing", "barThickness", "barBorderWidth",
	"trayIconSize", "trayIconGap",
	"popupCloseDelay", "notifyScale", "notifyTimeout", "notifyVisibleRows",
	"launcherMaxRows", "launcherSpotlightMaxRows", "launcherGridColumns", "launcherGridRows",
	"calendarWeekStart", "calendarBirthYear", "calendarLifeExpectancy",
	"cpuTopCount", "memoryTopCount", "memoryWarnAt", "memoryDangerAt", "mixerMaxVolume",
	"weatherDays", "contribWeeks", "wallpaperTransitionMs",
	"lockAfterMinutes", "lockSleepAfterMinutes", "lockFontSize", "powerWarnAt", "powerDangerAt"
];

var categories = [
	{ id: "appearance", name: "Appearance", glyph: "appearance", sections: ["colors", "shell"] },
	{ id: "bar", name: "Top bar", glyph: "bar", sections: ["bar", "tray"] },
	{ id: "display", name: "Display", glyph: "display", sections: [] },
	{ id: "wallpaper", name: "Wallpaper", glyph: "wallpaper", sections: ["wallpaper"] },
	{ id: "panels", name: "Panels", glyph: "panels", sections: ["popup", "tooltip", "notify", "calendar", "launcher", "windows"] },
	{ id: "widgets", name: "Widgets", glyph: "widgets", sections: ["cpu", "memory", "mixer", "media", "network", "weather", "contrib", "agent", "disk"] },
	{ id: "power", name: "Lock and power", glyph: "lock", sections: ["lock", "power"] }
];

var titles = {
	colors: "Colors", shell: "Type and spacing", bar: "Bar", tray: "Tray", wallpaper: "Wallpaper picker",
	popup: "Popups", tooltip: "Tooltips", notify: "Notifications", calendar: "Calendar", launcher: "Launcher",
	windows: "Window switcher", cpu: "Processor", memory: "Memory", mixer: "Volume mixer", media: "Now playing",
	network: "Network", weather: "Weather", contrib: "GitHub graph", agent: "Agent", disk: "Disk map",
	lock: "Lock screen", power: "Power"
};

var prefixes = {
	bar: ["bar"], tray: ["tray"], popup: ["popup"], tooltip: ["tooltip"], notify: ["notify"], calendar: ["calendar"],
	launcher: ["launcher"], windows: ["windows", "window"], cpu: ["cpu"], memory: ["memory"], mixer: ["mixer"],
	media: ["media"], network: ["network"], weather: ["weather"], contrib: ["contrib"], agent: ["agent"],
	disk: ["disk"], lock: ["lock"], power: ["power"], wallpaper: ["wallpaper"]
};

function label(key, section) {
	var rest = key;
	var own = prefixes[section] || [];
	for (var i = 0; i < own.length; i++) {
		var p = own[i];
		if (key.indexOf(p) === 0 && key.length > p.length && /[A-Z]/.test(key[p.length])) {
			rest = key.slice(p.length);
			break;
		}
	}
	var words = rest.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z])([A-Z][a-z])/g, "$1 $2").toLowerCase();
	words = words.replace(/\bms\b/, "(ms)").replace(/\bpos\b/, "position").replace(/\bcpu\b/, "CPU").replace(/\bx\b/, "X").replace(/\by\b/, "Y");
	return words.charAt(0).toUpperCase() + words.slice(1);
}

function note(comment) {
	if (!comment || /[()?"+*=]/.test(comment) || /^same as/.test(comment))
		return "";
	return comment.charAt(0).toUpperCase() + comment.slice(1);
}

function decode(body) {
	var out = "";
	for (var i = 0; i < body.length; i++) {
		var c = body[i];
		if (c !== "\\") {
			out += c;
			continue;
		}
		var e = body[++i];
		if (e === "u" || e === "U") {
			var n = e === "u" ? 4 : 8;
			out += String.fromCodePoint(parseInt(body.substr(i + 1, n), 16));
			i += n;
		} else {
			out += ({ n: "\n", t: "\t", r: "\r", b: "\b", f: "\f" })[e] || e;
		}
	}
	return out;
}

function literal(rest) {
	var q = rest[0];
	if (q === "\"") {
		for (var i = 1; i < rest.length; i++) {
			if (rest[i] === "\\") {
				i++;
				continue;
			}
			if (rest[i] === "\"")
				return { value: decode(rest.slice(1, i)), string: true, tail: rest.slice(i + 1) };
		}
		return null;
	}
	if (q === "'") {
		var close = rest.indexOf("'", 1);
		return close < 0 ? null : { value: rest.slice(1, close), string: true, tail: rest.slice(close + 1) };
	}
	var m = rest.match(/^([^\s#]+)(.*)$/);
	if (!m)
		return null;
	if (m[1] === "true" || m[1] === "false")
		return { value: m[1] === "true", bool: true, tail: m[2] };
	var n = Number(m[1]);
	if (isNaN(n))
		return null;
	return { value: n, float: /[.eE]/.test(m[1]), tail: m[2] };
}

function typeOf(key, lit) {
	if (lit.bool)
		return "bool";
	if (!lit.string)
		return lit.float ? "float" : "int";
	if (enums[key])
		return "enum";
	if (/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(lit.value))
		return "color";
	if (lit.value.length > 0 && lit.value.length <= 2 && lit.value.codePointAt(0) >= 0xe000)
		return "glyph";
	return "text";
}

function isAdvanced(key, type) {
	if (type === "bool" || type === "enum" || type === "color")
		return false;
	return primary.indexOf(key) < 0;
}

function parse(text) {
	var sections = [];
	var values = {};
	var current = null;
	var note = "";
	var depth = 0;
	var lines = String(text).split("\n");

	for (var i = 0; i < lines.length; i++) {
		var line = lines[i].trim();

		if (depth > 0) {
			depth += (line.match(/[\[{]/g) || []).length - (line.match(/[\]}]/g) || []).length;
			continue;
		}
		if (line === "") {
			note = "";
			continue;
		}
		if (line[0] === "#") {
			note = line.replace(/^#\s*/, "");
			continue;
		}
		var head = line.match(/^\[([A-Za-z0-9_.-]+)\]/);
		if (head) {
			current = { name: head[1], comment: note, keys: [] };
			sections.push(current);
			note = "";
			continue;
		}
		var kv = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(.*)$/);
		if (!kv || !current)
			continue;
		var rest = kv[2];
		if (rest[0] === "[" || rest[0] === "{") {
			depth = (rest.match(/[\[{]/g) || []).length - (rest.match(/[\]}]/g) || []).length;
			continue;
		}
		var lit = literal(rest);
		if (!lit)
			continue;
		var comment = lit.tail.replace(/^\s*#?\s*/, "");
		current.keys.push({ section: current.name, key: kv[1], value: lit.value, type: typeOf(kv[1], lit), comment: comment, advanced: isAdvanced(kv[1], typeOf(kv[1], lit)) });
		values[kv[1]] = lit.value;
		note = "";
	}

	return { sections: sections, values: values };
}

var ranges = {
	fontSize: [8, 24], iconSize: [6, 24], spacing: [0, 32], gapsIn: [0, 24], gapsOut: [0, 32], workspaceSpacing: [0, 24],
	barCells: [4, 30], barPadding: [0, 32], barInset: [0, 24], barStatSpacing: [0, 40], barThickness: [0, 4], barBorderWidth: [-1, 6],
	trayIconSize: [8, 32], trayIconGap: [0, 24], popupCloseDelay: [0, 500], notifyScale: [0.75, 2], notifyTimeout: [1000, 20000],
	notifyVisibleRows: [1, 12], launcherMaxRows: [4, 20], launcherSpotlightMaxRows: [4, 16], launcherGridColumns: [3, 10],
	launcherGridRows: [2, 8], calendarWeekStart: [0, 6], calendarLifeExpectancy: [50, 110], cpuTopCount: [1, 12],
	memoryTopCount: [1, 12], memoryWarnAt: [0, 100], memoryDangerAt: [0, 100], mixerMaxVolume: [0.5, 1.5], weatherDays: [1, 14],
	contribWeeks: [4, 52], wallpaperTransitionMs: [0, 2000], lockAfterMinutes: [0, 60], lockSleepAfterMinutes: [0, 120],
	lockFontSize: [8, 32], powerWarnAt: [0, 100], powerDangerAt: [0, 100]
};

function nice(x) {
	var p = Math.pow(10, Math.floor(Math.log(x) / Math.LN10));
	var f = x / p;
	return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p;
}

function steps(base, type, key) {
	var range = ranges[key];
	var top = Math.abs(base) > 0 ? Math.abs(base) * 2 : (type === "float" ? 1 : 10);
	var low = base < 0 ? base : 0;
	if (range) {
		low = Math.min(range[0], base);
		top = Math.max(range[1], base);
	}
	var span = top - low;
	var step = type === "int" ? Math.max(1, nice(span / 24)) : nice(span / 20);
	var out = [];
	for (var v = low; v <= top + step / 2; v += step)
		out.push(type === "int" ? Math.round(v) : Number((Math.round(v / step) * step).toFixed(6)));
	if (out.indexOf(base) < 0) {
		out.push(base);
		out.sort(function (x, y) { return x - y; });
	}
	return out;
}

function nearest(options, value) {
	var best = 0;
	for (var i = 1; i < options.length; i++) {
		if (Math.abs(options[i] - value) < Math.abs(options[best] - value))
			best = i;
	}
	return best;
}

function copyLayout(doc) {
	var out = JSON.parse(JSON.stringify(doc || {}));
	out.version = out.version || 1;
	out.bar = out.bar || {};
	out.bar.layout = out.bar.layout || {};
	["left", "center", "right"].forEach(function (slot) {
		out.bar.layout[slot] = (out.bar.layout[slot] || []).filter(function (e) { return e && e.id; });
	});
	return out;
}

function placed(doc, id) {
	var layout = copyLayout(doc).bar.layout;
	return ["left", "center", "right"].some(function (slot) {
		return layout[slot].some(function (e) { return e.id === id; });
	});
}

function move(doc, fromSlot, fromIndex, toSlot, toIndex) {
	var out = copyLayout(doc);
	var layout = out.bar.layout;
	var entry = fromSlot ? layout[fromSlot].splice(fromIndex, 1)[0] : { id: fromIndex };
	if (!entry)
		return out;
	if (!fromSlot && placed(out, entry.id))
		return out;
	if (fromSlot === toSlot && toIndex > fromIndex)
		toIndex -= 1;
	if (toSlot)
		layout[toSlot].splice(Math.max(0, Math.min(toIndex, layout[toSlot].length)), 0, entry);
	if (!placed(out, out.bar.centerAnchor))
		out.bar.centerAnchor = layout.center.length > 0 ? layout.center[0].id : "";
	return out;
}
