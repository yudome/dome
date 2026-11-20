.pragma library

var enums = {
	barStatMode: ["icon", "text"],
	popupPos: ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"],
	launcherMove: ["remember", "forget"],
	weatherTempUnit: ["fahrenheit", "celsius"]
};

var primary = [
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
		current.keys.push({ key: kv[1], value: lit.value, type: typeOf(kv[1], lit), comment: comment, advanced: (lit.float !== undefined) && primary.indexOf(kv[1]) < 0 });
		values[kv[1]] = lit.value;
		note = "";
	}

	return { sections: sections, values: values };
}

function nice(x) {
	var p = Math.pow(10, Math.floor(Math.log(x) / Math.LN10));
	var f = x / p;
	return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p;
}

function steps(base, type) {
	var top = Math.abs(base) > 0 ? Math.abs(base) * 2 : (type === "float" ? 1 : 10);
	var step = type === "int" ? Math.max(1, nice(top / 24)) : nice(top / 20);
	var out = [];
	var low = base < 0 ? base : 0;
	for (var v = low; v <= top + step / 2; v += step)
		out.push(type === "int" ? Math.round(v) : Math.round(v / step) * step);
	return out.map(function (v) { return type === "int" ? v : Number(v.toFixed(6)); });
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
