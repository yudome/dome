const std = @import("std");
const hubmod = @import("../hub.zig");
const configmod = @import("../primitives/config.zig");
const proc = @import("../primitives/proc.zig");
const watch = @import("../primitives/watch.zig");
const json = @import("../primitives/json.zig");
const exec = @import("../primitives/exec.zig");
const calc = @import("../primitives/calc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Hub = hubmod.Hub;

pub const Config = struct {
	allocator: Allocator,
	io: Io,
	hub: *Hub,
	mutex: std.Io.Mutex = .init,
	state: configmod.Config,

	pub fn create(allocator: Allocator, io: Io, hub: *Hub) !*Config {
		const self = try allocator.create(Config);
		self.* = .{
			.allocator = allocator,
			.io = io,
			.hub = hub,
			.state = try configmod.Config.parse(allocator, ""),
		};

		return self;
	}

	pub fn provider(self: *Config) hubmod.Provider {
		return .{ .key = "settings", .ctx = self, .render = renderThunk };
	}

	fn renderThunk(ctx: *anyopaque, writer: *Writer) anyerror!void {
		const self: *Config = @ptrCast(@alignCast(ctx));
		try self.render(writer);
	}

	pub fn start(self: *Config) !void {
		const thread = try std.Thread.spawn(.{}, watchLoop, .{self});
		thread.detach();
	}

	fn path(self: *Config, allocator: Allocator) []const u8 {
		return std.fmt.allocPrint(allocator, "{s}/dotfiles/shell/config.toml", .{proc.home(self.io, allocator)}) catch "/nonexistent";
	}

	fn themePath(self: *Config, allocator: Allocator) []const u8 {
		return std.fmt.allocPrint(allocator, "{s}/yudae/theme.toml", .{proc.stateHome(self.io, allocator)}) catch "/nonexistent";
	}

	fn cachePath(self: *Config, allocator: Allocator) []const u8 {
		return std.fmt.allocPrint(allocator, "{s}/shell/cache/settings.json", .{proc.repo(self.io, allocator)}) catch "/nonexistent";
	}

	fn watchLoop(self: *Config) void {
		self.reload();

		const file = self.path(self.allocator);
		defer self.allocator.free(file);

		watch.watchFile(self.io, self.allocator, file, self, reloadThunk) catch {};
	}

	fn reloadThunk(ctx: *anyopaque) void {
		const self: *Config = @ptrCast(@alignCast(ctx));
		self.reload();
	}

	pub fn reload(self: *Config) void {
		const file = self.path(self.allocator);
		defer self.allocator.free(file);

		const body = proc.readFile(self.io, self.allocator, file) catch return;
		defer self.allocator.free(body);

		const theme_file = self.themePath(self.allocator);
		defer self.allocator.free(theme_file);
		const theme = proc.readFile(self.io, self.allocator, theme_file) catch "";

		var combined: std.ArrayList(u8) = .empty;
		defer combined.deinit(self.allocator);
		if (body.len > 0) combined.appendSlice(self.allocator, body) catch return;
		combined.append(self.allocator, '\n') catch return;
		if (theme.len > 0) {
			combined.appendSlice(self.allocator, theme) catch return;
			self.allocator.free(theme);
		}

		const next = configmod.Config.parse(self.allocator, combined.items) catch return;

		self.mutex.lockUncancelable(self.io);
		const previous = self.state;
		self.state = next;
		self.mutex.unlock(self.io);

		previous.deinit();
		self.writeCache();

		self.hub.publish();
	}

	fn writeCache(self: *Config) void {
		var out: Writer.Allocating = .init(self.allocator);
		defer out.deinit();

		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		self.state.render(&out.writer) catch return;

		const cache = self.cachePath(self.allocator);
		defer self.allocator.free(cache);
		proc.writeFileAtomic(self.io, self.allocator, cache, out.written()) catch {};
	}

	fn render(self: *Config, writer: *Writer) !void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		try self.state.render(writer);
	}

	pub fn call(self: *Config, method: []const u8, args: json.Value, alloc: Allocator) ![]u8 {
		if (std.mem.eql(u8, method, "set")) return self.set(args, alloc);
		if (std.mem.eql(u8, method, "get")) return self.get(args, alloc);
		if (std.mem.eql(u8, method, "schema")) return schema(alloc, try proc.readFile(self.io, alloc, self.path(alloc)));
		if (std.mem.eql(u8, method, "app")) return openApp(self.io, alloc, "settings", json.textAt(args, "pane"));
		return error.UnknownMethod;
	}

	fn set(self: *Config, args: json.Value, alloc: Allocator) ![]u8 {
		const name = json.textAt(args, "key");
		const value = json.field(args, "value") orelse return error.NoValue;
		if (name.len == 0) return error.NoKey;

		const file = self.path(alloc);
		const body = try proc.readFile(self.io, alloc, file);
		const next = try propagate(alloc, try rewrite(alloc, body, name, value), name, value, 0);

		(try configmod.Config.parse(alloc, next)).deinit();
		try proc.writeFileAtomic(self.io, alloc, file, next);
		self.reload();

		return alloc.dupe(u8, "{\"ok\":true}");
	}

	fn get(self: *Config, args: json.Value, alloc: Allocator) ![]u8 {
		const name = json.textAt(args, "key");
		const cfg = try configmod.Config.parse(alloc, try proc.readFile(self.io, alloc, self.path(alloc)));
		defer cfg.deinit();

		var out: Writer.Allocating = .init(alloc);
		if (name.len == 0) {
			try cfg.render(&out.writer);
			return out.toOwnedSlice();
		}

		try writeConfigValue(&out.writer, cfg.get(name) orelse return error.UnknownKey);
		return out.toOwnedSlice();
	}
};

pub fn openApp(io: Io, alloc: Allocator, name: []const u8, pane: []const u8) ![]u8 {
	const script = try std.fmt.allocPrint(alloc, "{s}/scripts/yudae", .{proc.repo(io, alloc)});
	const argv = try appArgv(alloc, script, name, pane);
	_ = exec.spawn(io, .{
		.argv = argv,
		.stdin = .ignore,
		.stdout = .ignore,
		.stderr = .ignore,
	}) catch return error.SpawnFailed;

	return alloc.dupe(u8, "{\"ok\":true}");
}

fn appArgv(alloc: Allocator, script: []const u8, name: []const u8, pane: []const u8) ![]const []const u8 {
	if (std.mem.indexOfNone(u8, pane, "abcdefghijklmnopqrstuvwxyz") != null) return error.BadPane;
	if (pane.len == 0) return alloc.dupe([]const u8, &.{ "setsid", script, "app", "open", name });
	return alloc.dupe([]const u8, &.{ "setsid", script, "app", "open", name, "--pane", pane });
}

test "settings.app opens the settings app, on a pane when one is named" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const plain = try appArgv(a, "/r/scripts/yudae", "settings", "");
	try std.testing.expectEqual(@as(usize, 5), plain.len);
	try std.testing.expectEqualStrings("settings", plain[4]);

	const pane = try appArgv(a, "/r/scripts/yudae", "settings", "display");
	try std.testing.expectEqualStrings("--pane", pane[5]);
	try std.testing.expectEqualStrings("display", pane[6]);

	try std.testing.expectError(error.BadPane, appArgv(a, "/r/scripts/yudae", "settings", "a b"));
}

const Literal = enum { string, integer, float, boolean };

pub fn rewrite(alloc: Allocator, body: []const u8, name: []const u8, value: json.Value) ![]u8 {
	var start: usize = 0;

	while (start < body.len) {
		const end = std.mem.indexOfScalarPos(u8, body, start, '\n') orelse body.len;
		const line = body[start..end];
		const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
		const rest = line[indent..];

		if (std.mem.startsWith(u8, rest, name) and rest.len > name.len and (rest[name.len] == ' ' or rest[name.len] == '=')) {
			const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.UnknownKey;
			const head = rest[name.len..eq];
			if (std.mem.trim(u8, head, " \t").len != 0) return error.UnknownKey;

			var at = eq + 1;
			while (at < rest.len and (rest[at] == ' ' or rest[at] == '\t')) at += 1;
			const span = try literalEnd(rest, at);

			var out: Writer.Allocating = .init(alloc);
			try out.writer.writeAll(body[0 .. start + indent + at]);
			try writeLiteral(&out.writer, span.kind, value);
			try out.writer.writeAll(body[start + indent + span.end ..]);
			return out.toOwnedSlice();
		}

		start = end + 1;
	}

	return error.UnknownKey;
}

fn literalEnd(rest: []const u8, at: usize) !struct { end: usize, kind: Literal } {
	if (at >= rest.len) return error.Unsupported;

	switch (rest[at]) {
		'"' => {
			var index = at + 1;
			while (index < rest.len) : (index += 1) {
				if (rest[index] == '\\') {
					index += 1;
					continue;
				}
				if (rest[index] == '"') return .{ .end = index + 1, .kind = .string };
			}
			return error.Unsupported;
		},
		'\'' => {
			const close = std.mem.indexOfScalarPos(u8, rest, at + 1, '\'') orelse return error.Unsupported;
			return .{ .end = close + 1, .kind = .string };
		},
		'[', '{' => return error.Unsupported,
		else => {
			var index = at;
			while (index < rest.len and rest[index] != ' ' and rest[index] != '\t' and rest[index] != '#') index += 1;
			const word = rest[at..index];

			if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) return .{ .end = index, .kind = .boolean };
			if (std.mem.indexOfAny(u8, word, ".eE") != null) return .{ .end = index, .kind = .float };
			_ = std.fmt.parseInt(i64, word, 10) catch return error.Unsupported;
			return .{ .end = index, .kind = .integer };
		},
	}
}

fn writeLiteral(writer: *Writer, kind: Literal, value: json.Value) !void {
	switch (kind) {
		.boolean => switch (value) {
			.bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
			else => return error.WrongType,
		},
		.integer => switch (value) {
			.integer => |number| try writer.print("{d}", .{number}),
			.float => |number| {
				if (number != @floor(number) or !std.math.isFinite(number)) return error.WrongType;
				try writer.print("{d}", .{@as(i64, @intFromFloat(number))});
			},
			else => return error.WrongType,
		},
		.float => {
			const number: f64 = switch (value) {
				.integer => |n| @floatFromInt(n),
				.float => |n| n,
				else => return error.WrongType,
			};
			if (!std.math.isFinite(number)) return error.WrongType;

			var buffer: [64]u8 = undefined;
			const text = try std.fmt.bufPrint(&buffer, "{d}", .{number});
			try writer.writeAll(text);
			if (std.mem.indexOfAny(u8, text, ".e") == null) try writer.writeAll(".0");
		},
		.string => switch (value) {
			.string => |text| try writeString(writer, text),
			else => return error.WrongType,
		},
	}
}

fn writeString(writer: *Writer, text: []const u8) !void {
	if (!std.unicode.utf8ValidateSlice(text)) return error.WrongType;

	try writer.writeByte('"');
	var view = std.unicode.Utf8View.initUnchecked(text).iterator();
	while (view.nextCodepoint()) |point| {
		switch (point) {
			'"' => try writer.writeAll("\\\""),
			'\\' => try writer.writeAll("\\\\"),
			0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(@intCast(point)),
			0...0x1f, 0x7f...0xffff => try writer.print("\\u{X:0>4}", .{point}),
			else => try writer.print("\\U{X:0>8}", .{point}),
		}
	}
	try writer.writeByte('"');
}

test "settings.set rewrites one line and keeps comments, order and types" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const body =
		"[bar]\n" ++
		"barCellsWide = 3\n" ++
		"barCells = 15  # the cells\n" ++
		"barThickness = 1.5\n" ++
		"barFloating = false\n" ++
		"\tclockFormat = \"h:mm\" # time\n" ++
		"icon = \"\\uF00D\"\n";

	const cells = try rewrite(a, body, "barCells", .{ .integer = 12 });
	try std.testing.expect(std.mem.indexOf(u8, cells, "barCells = 12  # the cells\n") != null);
	try std.testing.expect(std.mem.indexOf(u8, cells, "barCellsWide = 3\n") != null);

	const thick = try rewrite(a, body, "barThickness", .{ .integer = 2 });
	try std.testing.expect(std.mem.indexOf(u8, thick, "barThickness = 2.0\n") != null);

	const flag = try rewrite(a, body, "barFloating", .{ .bool = true });
	try std.testing.expect(std.mem.indexOf(u8, flag, "barFloating = true\n") != null);

	const clock = try rewrite(a, body, "clockFormat", .{ .string = "a \"b\" \u{f00d}" });
	try std.testing.expect(std.mem.indexOf(u8, clock, "\tclockFormat = \"a \\\"b\\\" \\uF00D\" # time\n") != null);

	const icon = try rewrite(a, body, "icon", .{ .string = "\u{f0379}" });
	try std.testing.expect(std.mem.indexOf(u8, icon, "icon = \"\\U000F0379\"\n") != null);
	const parsed = try configmod.Config.parse(a, icon);
	try std.testing.expectEqualStrings("\u{f0379}", parsed.color("icon").?);

	try std.testing.expectEqualStrings(body, try rewrite(a, body, "barCells", .{ .integer = 15 }));
	try std.testing.expectError(error.WrongType, rewrite(a, body, "barCells", .{ .string = "x" }));
	try std.testing.expectError(error.WrongType, rewrite(a, body, "barCells", .{ .float = 1.5 }));
	try std.testing.expectError(error.WrongType, rewrite(a, body, "barFloating", .{ .integer = 1 }));
	try std.testing.expectError(error.UnknownKey, rewrite(a, body, "missing", .{ .integer = 1 }));
	try std.testing.expectError(error.Unsupported, rewrite(a, "list = [1, 2]\n", "list", .{ .integer = 1 }));
}

test "a broken edit keeps the config it already had" {
	var hub: hubmod.Hub = .{ .allocator = std.testing.allocator, .io = std.Io.Threaded.global_single_threaded.io() };

	const self = try Config.create(std.testing.allocator, hub.io, &hub);
	defer {
		self.state.deinit();
		std.testing.allocator.destroy(self);
	}

	const good = try configmod.Config.parse(std.testing.allocator, "[colors]\nsurface = \"#101010\"\n");
	self.state.deinit();
	self.state = good;

	const broken = configmod.Config.parse(std.testing.allocator, "surface = ");
	try std.testing.expectError(error.InvalidToml, broken);

	try std.testing.expectEqualStrings("#101010", self.state.color("surface").?);
}

const Meta = struct {
	hidden: bool = false,
	options: []const u8 = "",
	low: ?f64 = null,
	high: ?f64 = null,
	note: []const u8 = "",
};

fn metaOf(comment: []const u8) Meta {
	const text = std.mem.trim(u8, comment, " \t");
	if (text.len == 0) return .{};
	if (std.mem.eql(u8, text, "hidden") or derivedComment(text)) return .{ .hidden = true };
	if (std.mem.indexOf(u8, text, " | ") != null) return .{ .options = text };
	if (std.mem.indexOf(u8, text, "..")) |dots| {
		const low = std.fmt.parseFloat(f64, std.mem.trim(u8, text[0..dots], " ")) catch return .{ .note = text };
		const rest = std.mem.trim(u8, text[dots + 2 ..], " ");
		const high = std.fmt.parseFloat(f64, rest) catch return .{ .note = text };
		return .{ .low = low, .high = high };
	}
	return .{ .note = text };
}

fn derivedComment(text: []const u8) bool {
	return std.mem.startsWith(u8, text, "same as ") or std.mem.indexOfAny(u8, text, "()?*/+\"") != null;
}

const KeyLine = struct { key: []const u8, comment: []const u8, kind: Literal };

const Line = struct {
	key: []const u8 = "",
	section: []const u8 = "",
	title: []const u8 = "",
	comment: []const u8 = "",
	kind: ?Literal = null,
};

fn lines(alloc: Allocator, body: []const u8) ![]Line {
	var out: std.ArrayList(Line) = .empty;
	var depth: i32 = 0;
	var note: []const u8 = "";
	var it = std.mem.splitScalar(u8, body, '\n');

	while (it.next()) |raw| {
		const line = std.mem.trim(u8, raw, " \t\r");

		if (depth > 0) {
			depth += brackets(line);
			continue;
		}
		if (line.len == 0) {
			note = "";
			continue;
		}
		if (line[0] == '#') {
			note = std.mem.trim(u8, line[1..], " ");
			continue;
		}
		if (line[0] == '[') {
			const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
			try out.append(alloc, .{ .section = line[1..close], .title = note });
			note = "";
			continue;
		}

		const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..eq], " \t");
		var at = eq + 1;
		while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
		note = "";

		if (at < line.len and (line[at] == '[' or line[at] == '{')) {
			depth = brackets(line[at..]);
			continue;
		}

		const span = literalEnd(line, at) catch continue;
		const tail = std.mem.trim(u8, line[span.end..], " \t");
		const comment = if (tail.len > 0 and tail[0] == '#') std.mem.trim(u8, tail[1..], " \t") else "";
		try out.append(alloc, .{ .key = key, .comment = comment, .kind = span.kind });
	}

	return out.toOwnedSlice(alloc);
}

fn brackets(line: []const u8) i32 {
	var count: i32 = 0;
	var quoted = false;
	for (line, 0..) |c, i| {
		if (c == '"' and (i == 0 or line[i - 1] != '\\')) quoted = !quoted;
		if (quoted) continue;
		if (c == '#') break;
		if (c == '[' or c == '{') count += 1;
		if (c == ']' or c == '}') count -= 1;
	}
	return count;
}

pub fn label(alloc: Allocator, key: []const u8, section: []const u8) ![]u8 {
	var rest = key;
	const trimmed = if (section.len > 1 and section[section.len - 1] == 's') section[0 .. section.len - 1] else section;
	for ([_][]const u8{ section, trimmed }) |prefix| {
		if (prefix.len > 0 and key.len > prefix.len and std.mem.startsWith(u8, key, prefix) and std.ascii.isUpper(key[prefix.len])) {
			rest = key[prefix.len..];
			break;
		}
	}

	var words: std.ArrayList([]u8) = .empty;
	var start: usize = 0;
	for (rest, 0..) |c, i| {
		if (i == 0) continue;
		const prev = rest[i - 1];
		const split = std.ascii.isUpper(c) and (std.ascii.isLower(prev) or std.ascii.isDigit(prev) or (i + 1 < rest.len and std.ascii.isLower(rest[i + 1]) and std.ascii.isUpper(prev)));
		if (!split) continue;
		try words.append(alloc, try std.ascii.allocLowerString(alloc, rest[start..i]));
		start = i;
	}
	try words.append(alloc, try std.ascii.allocLowerString(alloc, rest[start..]));

	var out: std.ArrayList(u8) = .empty;
	for (words.items, 0..) |word, i| {
		if (i > 0) try out.append(alloc, ' ');
		const swapped: []const u8 = if (std.mem.eql(u8, word, "ms")) "(ms)" else if (std.mem.eql(u8, word, "pos")) "position" else if (std.mem.eql(u8, word, "cpu")) "CPU" else if (word.len == 1) &.{std.ascii.toUpper(word[0])} else word;
		try out.appendSlice(alloc, swapped);
	}
	if (out.items.len > 0) out.items[0] = std.ascii.toUpper(out.items[0]);
	return out.toOwnedSlice(alloc);
}

fn kindOf(kind: Literal, value: configmod.Value, meta: Meta) []const u8 {
	return switch (kind) {
		.boolean => "bool",
		.integer => "int",
		.float => "float",
		.string => blk: {
			if (meta.options.len > 0) break :blk "enum";
			const text = switch (value) {
				.string => |t| t,
				else => break :blk "text",
			};
			if (text.len == 7 or text.len == 9) {
				if (text[0] == '#' and std.mem.indexOfNone(u8, text[1..], "0123456789abcdefABCDEF") == null) break :blk "color";
			}
			if (text.len > 0 and text.len <= 4) {
				const length = std.unicode.utf8ByteSequenceLength(text[0]) catch break :blk "text";
				if (length == text.len) {
					const point = std.unicode.utf8Decode(text) catch break :blk "text";
					if (point >= 0xe000) break :blk "glyph";
				}
			}
			break :blk "text";
		},
	};
}

fn niceStep(x: f64) f64 {
	if (x <= 0) return 1;
	const p = std.math.pow(f64, 10, @floor(std.math.log10(x)));
	const f = x / p;
	const m: f64 = if (f < 1.5) 1 else if (f < 3.5) 2 else if (f < 7.5) 5 else 10;
	return m * p;
}

pub fn steps(alloc: Allocator, base: f64, integer: bool, meta: Meta) ![]f64 {
	var low: f64 = if (base < 0) base else 0;
	var high: f64 = if (@abs(base) > 0) @abs(base) * 2 else if (integer) 10 else 1;
	if (meta.low) |l| low = @min(l, base);
	if (meta.high) |h| high = @max(h, base);

	const span = high - low;
	const step = if (integer) @max(1, niceStep(span / 24)) else niceStep(span / 20);
	var out: std.ArrayList(f64) = .empty;
	var have = false;
	var v = low;
	while (v <= high + step / 2) : (v += step) {
		const value = if (integer) @round(v) else @round(v / step) * step;
		if (value == base) have = true;
		try out.append(alloc, value);
	}
	if (!have) {
		var at: usize = 0;
		while (at < out.items.len and out.items[at] < base) at += 1;
		try out.insert(alloc, at, base);
	}
	return out.toOwnedSlice(alloc);
}

fn writeConfigValue(w: *Writer, value: configmod.Value) !void {
	switch (value) {
		.string => |t| try std.json.Stringify.encodeJsonString(t, .{}, w),
		.integer => |n| try w.print("{d}", .{n}),
		.float => |n| try w.print("{d}", .{n}),
		.boolean => |b| try w.writeAll(if (b) "true" else "false"),
		.array => |items| {
			try w.writeByte('[');
			for (items, 0..) |item, i| {
				if (i > 0) try w.writeByte(',');
				try writeConfigValue(w, item);
			}
			try w.writeByte(']');
		},
		.table => |table| {
			try w.writeByte('{');
			for (table.entries.items, 0..) |entry, i| {
				if (i > 0) try w.writeByte(',');
				try std.json.Stringify.encodeJsonString(entry.key, .{}, w);
				try w.writeByte(':');
				try writeConfigValue(w, entry.value);
			}
			try w.writeByte('}');
		},
	}
}

fn tableText(table: *configmod.Table, name: []const u8) []const u8 {
	for (table.entries.items) |entry| {
		if (std.mem.eql(u8, entry.key, name)) return switch (entry.value) {
			.string => |t| t,
			else => "",
		};
	}
	return "";
}

fn tableList(table: *configmod.Table, name: []const u8) []const configmod.Value {
	for (table.entries.items) |entry| {
		if (std.mem.eql(u8, entry.key, name)) return switch (entry.value) {
			.array => |items| items,
			else => &.{},
		};
	}
	return &.{};
}

fn writeSection(alloc: Allocator, w: *Writer, cfg: configmod.Config, all: []const Line, name: []const u8) !bool {
	var start: ?usize = null;
	for (all, 0..) |line, i| {
		if (line.key.len == 0 and std.mem.eql(u8, line.section, name)) start = i;
	}
	const first = start orelse return false;

	var count: usize = 0;
	for (all[first + 1 ..]) |line| {
		if (line.key.len == 0) break;
		if (!metaOf(line.comment).hidden) count += 1;
	}
	if (count == 0) return false;

	try w.writeAll("{\"name\":");
	try std.json.Stringify.encodeJsonString(name, .{}, w);
	try w.writeAll(",\"title\":");
	const title = if (all[first].title.len > 0) all[first].title else try label(alloc, name, "");
	try std.json.Stringify.encodeJsonString(title, .{}, w);
	try w.writeAll(",\"keys\":[");

	var wrote = false;
	for (all[first + 1 ..]) |line| {
		if (line.key.len == 0) break;
		const meta = metaOf(line.comment);
		if (meta.hidden) continue;
		const value = cfg.get(line.key) orelse continue;
		const kind = kindOf(line.kind.?, value, meta);

		if (wrote) try w.writeByte(',');
		wrote = true;
		try w.writeAll("{\"key\":");
		try std.json.Stringify.encodeJsonString(line.key, .{}, w);
		try w.writeAll(",\"label\":");
		try std.json.Stringify.encodeJsonString(try label(alloc, line.key, name), .{}, w);
		try w.print(",\"type\":\"{s}\",\"value\":", .{kind});
		try writeConfigValue(w, value);
		try w.writeAll(",\"note\":");
		try std.json.Stringify.encodeJsonString(meta.note, .{}, w);

		if (meta.options.len > 0) {
			try w.writeAll(",\"options\":[");
			var parts = std.mem.splitSequence(u8, meta.options, "|");
			var i: usize = 0;
			while (parts.next()) |part| : (i += 1) {
				if (i > 0) try w.writeByte(',');
				try std.json.Stringify.encodeJsonString(std.mem.trim(u8, part, " "), .{}, w);
			}
			try w.writeByte(']');
		}

		if (line.kind.? == .integer or line.kind.? == .float) {
			const base: f64 = switch (value) {
				.integer => |n| @floatFromInt(n),
				.float => |n| n,
				else => 0,
			};
			try w.writeAll(",\"steps\":[");
			for (try steps(alloc, base, line.kind.? == .integer, meta), 0..) |step, i| {
				if (i > 0) try w.writeByte(',');
				try w.print("{d}", .{step});
			}
			try w.writeByte(']');
		}
		try w.writeByte('}');
	}

	try w.writeAll("]}");
	return true;
}

pub fn schema(alloc: Allocator, body: []const u8) ![]u8 {
	const cfg = try configmod.Config.parse(alloc, body);
	defer cfg.deinit();
	const all = try lines(alloc, body);

	var out: Writer.Allocating = .init(alloc);
	const w = &out.writer;
	var listed: std.StringHashMapUnmanaged(void) = .empty;

	try w.writeAll("{\"apply\":");
	const apply = switch (cfg.get("settingsApply") orelse configmod.Value{ .string = "instant" }) {
		.string => |t| t,
		else => "instant",
	};
	try std.json.Stringify.encodeJsonString(apply, .{}, w);
	try w.writeAll(",\"pages\":[");

	var pages: usize = 0;
	const declared = switch (cfg.get("settingsPages") orelse configmod.Value{ .array = &.{} }) {
		.array => |items| items,
		else => &.{},
	};

	for (declared) |entry| {
		const table = switch (entry) {
			.table => |t| t,
			else => continue,
		};
		if (pages > 0) try w.writeByte(',');
		pages += 1;
		try w.writeAll("{\"name\":");
		try std.json.Stringify.encodeJsonString(tableText(table, "name"), .{}, w);
		try w.writeAll(",\"glyph\":");
		try std.json.Stringify.encodeJsonString(tableText(table, "glyph"), .{}, w);
		try w.writeAll(",\"sections\":[");
		var wrote = false;
		for (tableList(table, "sections")) |item| {
			const name = switch (item) {
				.string => |t| t,
				else => continue,
			};
			try listed.put(alloc, name, {});
			if (wrote) try w.writeByte(',');
			if (try writeSection(alloc, w, cfg, all, name)) {
				wrote = true;
			} else if (wrote) {
				out.writer.undo(1);
			}
		}
		try w.writeAll("]}");
	}

	var other = false;
	for (all) |line| {
		if (line.key.len != 0 or listed.contains(line.section)) continue;
		var probe: Writer.Allocating = .init(alloc);
		if (!try writeSection(alloc, &probe.writer, cfg, all, line.section)) continue;
		if (!other) {
			if (pages > 0) try w.writeByte(',');
			try w.writeAll("{\"name\":\"Other\",\"glyph\":\"settings\",\"sections\":[");
			other = true;
		} else try w.writeByte(',');
		try w.writeAll(probe.written());
	}
	if (other) try w.writeAll("]}");

	try w.writeAll("]}");
	return out.toOwnedSlice();
}

fn references(comment: []const u8, key: []const u8) bool {
	var at: usize = 0;
	while (std.mem.indexOfPos(u8, comment, at, key)) |found| {
		const before = found == 0 or !(std.ascii.isAlphanumeric(comment[found - 1]) or comment[found - 1] == '_');
		const end = found + key.len;
		const after = end >= comment.len or !(std.ascii.isAlphanumeric(comment[end]) or comment[end] == '_');
		if (before and after) return true;
		at = found + 1;
	}
	return false;
}

fn follow(alloc: Allocator, comment: []const u8, key: []const u8, value: json.Value) !?json.Value {
	if (std.mem.startsWith(u8, comment, "same as ")) {
		return if (std.mem.eql(u8, std.mem.trim(u8, comment["same as ".len..], " "), key)) value else null;
	}
	if (!references(comment, key)) return null;

	if (std.mem.indexOfScalar(u8, comment, '?')) |q| {
		const colon = std.mem.indexOfScalarPos(u8, comment, q, ':') orelse return null;
		if (!std.mem.eql(u8, std.mem.trim(u8, comment[0..q], " "), key)) return null;
		const flag = switch (value) {
			.bool => |b| b,
			else => return null,
		};
		const pick = std.mem.trim(u8, if (flag) comment[q + 1 .. colon] else comment[colon + 1 ..], " ");
		return .{ .float = std.fmt.parseFloat(f64, pick) catch return null };
	}

	const number: f64 = switch (value) {
		.integer => |n| @floatFromInt(n),
		.float => |n| n,
		else => return null,
	};
	var expr: std.ArrayList(u8) = .empty;
	var at: usize = 0;
	while (at < comment.len) {
		if (std.mem.startsWith(u8, comment[at..], "Math.")) {
			at += "Math.".len;
			continue;
		}
		if (std.mem.startsWith(u8, comment[at..], key) and (at == 0 or !std.ascii.isAlphanumeric(comment[at - 1]))) {
			try expr.print(alloc, "({d})", .{number});
			at += key.len;
			continue;
		}
		if (comment[at] != ' ') try expr.append(alloc, comment[at]);
		at += 1;
	}
	return .{ .float = calc.calculate(expr.items) orelse return null };
}

pub fn propagate(alloc: Allocator, body: []const u8, key: []const u8, value: json.Value, depth: usize) ![]u8 {
	if (depth > 4) return alloc.dupe(u8, body);

	var next = try alloc.dupe(u8, body);
	for (try lines(alloc, body)) |line| {
		if (line.key.len == 0 or line.comment.len == 0) continue;
		const derived = (try follow(alloc, line.comment, key, value)) orelse continue;
		const typed: json.Value = switch (derived) {
			.float => |n| if (line.kind.? == .integer) .{ .integer = @intFromFloat(@round(n)) } else derived,
			else => derived,
		};
		next = rewrite(alloc, next, line.key, typed) catch continue;
		next = try propagate(alloc, next, line.key, typed, depth + 1);
	}
	return next;
}

test "settings.schema reads pages, titles, types and hints from config.toml" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const body =
		\\[settings]
		\\settingsApply = "instant"  # instant | manual
		\\settingsPages = [
		\\  { name = "Look", glyph = "appearance", sections = ["bar"] },
		\\]
		\\
		\\# Bar
		\\[bar]
		\\barCells = 15  # 4..30
		\\barStatMode = "icon"  # icon | text
		\\barFloating = false
		\\barBorderWidth = 0  # barFloating ? -1 : 0
		\\barTitle = "x"  # hidden
		\\barColor = "#101010"
		\\barGlyph = "\uF013"
		\\
		\\[extra]
		\\extraSize = 2.5
	;

	const parsed = try json.parse(a, try schema(a, body));
	const root = parsed.value;
	try std.testing.expectEqualStrings("instant", json.textAt(root, "apply"));
	const pages = json.listAt(root, "pages");
	try std.testing.expectEqual(@as(usize, 2), pages.len);
	try std.testing.expectEqualStrings("Look", json.textAt(pages[0], "name"));
	try std.testing.expectEqualStrings("Other", json.textAt(pages[1], "name"));

	const bar = json.listAt(pages[0], "sections")[0];
	try std.testing.expectEqualStrings("Bar", json.textAt(bar, "title"));
	const keys = json.listAt(bar, "keys");
	try std.testing.expectEqual(@as(usize, 5), keys.len);
	try std.testing.expectEqualStrings("Cells", json.textAt(keys[0], "label"));
	try std.testing.expectEqualStrings("int", json.textAt(keys[0], "type"));
	try std.testing.expectEqual(@as(f64, 4), json.number(json.listAt(keys[0], "steps")[0]));
	try std.testing.expectEqualStrings("enum", json.textAt(keys[1], "type"));
	try std.testing.expectEqual(@as(usize, 2), json.listAt(keys[1], "options").len);
	try std.testing.expectEqualStrings("bool", json.textAt(keys[2], "type"));
	try std.testing.expectEqualStrings("color", json.textAt(keys[3], "type"));
	try std.testing.expectEqualStrings("glyph", json.textAt(keys[4], "type"));
	const others = json.listAt(pages[1], "sections");
	try std.testing.expectEqualStrings("Size", json.textAt(json.listAt(others[others.len - 1], "keys")[0], "label"));
}

test "labels drop the section prefix and read as words" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	try std.testing.expectEqualStrings("Cells", try label(a, "barCells", "bar"));
	try std.testing.expectEqualStrings("Sweep (ms)", try label(a, "barSweepMs", "bar"));
	try std.testing.expectEqualStrings("Step (ms)", try label(a, "windowStepMs", "windows"));
	try std.testing.expectEqualStrings("Workspace spacing", try label(a, "workspaceSpacing", "shell"));
	try std.testing.expectEqualStrings("Position", try label(a, "popupPos", "popup"));
	try std.testing.expectEqualStrings("Offset X", try label(a, "tooltipOffsetX", "tooltip"));
	try std.testing.expectEqualStrings("Top count", try label(a, "cpuTopCount", "cpu"));
}

test "slider steps cover the range and always hold the value" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const sizes = try steps(a, 12, true, .{ .low = 8, .high = 24 });
	try std.testing.expectEqual(@as(f64, 8), sizes[0]);
	try std.testing.expectEqual(@as(f64, 24), sizes[sizes.len - 1]);
	const odd = try steps(a, 0.37, false, .{ .low = 0, .high = 4 });
	try std.testing.expect(std.mem.indexOfScalar(f64, odd, 0.37) != null);
	try std.testing.expect(std.mem.indexOfScalar(f64, try steps(a, -1, true, .{}), -1) != null);
}

test "settings.set carries a change into the keys that copy or derive from it" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const body =
		"foreground = \"#ffffff\"\n" ++
		"muted = \"#ffffff\"  # same as foreground\n" ++
		"cpuMono = \"#ffffff\"  # same as muted\n" ++
		"notifyScale = 1.25\n" ++
		"notifyWidth = 350  # Math.round(280 * notifyScale)\n" ++
		"mixerStepCount = 10\n" ++
		"mixerStep = 0.1  # 1 / mixerStepCount\n" ++
		"barFloating = false\n" ++
		"barBorderWidth = 0  # barFloating ? -1 : 0\n";

	const ink = try propagate(a, try rewrite(a, body, "foreground", .{ .string = "#eeeeee" }), "foreground", .{ .string = "#eeeeee" }, 0);
	try std.testing.expect(std.mem.indexOf(u8, ink, "muted = \"#eeeeee\"  # same as foreground") != null);
	try std.testing.expect(std.mem.indexOf(u8, ink, "cpuMono = \"#eeeeee\"") != null);

	const scale = try propagate(a, body, "notifyScale", .{ .float = 1.5 }, 0);
	try std.testing.expect(std.mem.indexOf(u8, scale, "notifyWidth = 420  #") != null);

	const count = try propagate(a, body, "mixerStepCount", .{ .integer = 20 }, 0);
	try std.testing.expect(std.mem.indexOf(u8, count, "mixerStep = 0.05  #") != null);

	const floating = try propagate(a, body, "barFloating", .{ .bool = true }, 0);
	try std.testing.expect(std.mem.indexOf(u8, floating, "barBorderWidth = -1  #") != null);
}

test "the repo config.toml makes a settings schema" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const body = try proc.readFile(std.testing.io, a, "../shell/config.toml");
	const parsed = try json.parse(a, try schema(a, body));
	const pages = json.listAt(parsed.value, "pages");
	try std.testing.expectEqualStrings("General", json.textAt(pages[0], "name"));
	for (pages) |page| try std.testing.expect(!std.mem.eql(u8, json.textAt(page, "name"), "Other"));
}
