const std = @import("std");
const hubmod = @import("../hub.zig");
const configmod = @import("../primitives/config.zig");
const proc = @import("../primitives/proc.zig");
const watch = @import("../primitives/watch.zig");
const json = @import("../primitives/json.zig");
const stills = @import("stills.zig");
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
	changed: ?stills.Hook = null,

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

	fn dir(self: *Config, allocator: Allocator) []const u8 {
		return std.fmt.allocPrint(allocator, "{s}/dotfiles/shell/config", .{proc.home(self.io, allocator)}) catch "/nonexistent";
	}

	fn themePath(self: *Config, allocator: Allocator) []const u8 {
		return std.fmt.allocPrint(allocator, "{s}/yudae/theme.toml", .{proc.stateHome(self.io, allocator)}) catch "/nonexistent";
	}

	fn cachePath(self: *Config, allocator: Allocator) []const u8 {
		return std.fmt.allocPrint(allocator, "{s}/shell/cache/settings.json", .{proc.repo(self.io, allocator)}) catch "/nonexistent";
	}

	fn watchLoop(self: *Config) void {
		self.reload();

		const folder = self.dir(self.allocator);
		defer self.allocator.free(folder);

		var watcher = watch.Watcher.init() catch return;
		defer watcher.close();

		const sentinel = self.allocator.allocSentinel(u8, folder.len, 0) catch return;
		defer self.allocator.free(sentinel);
		@memcpy(sentinel, folder);

		watcher.add(sentinel) catch return;

		while (true) {
			_ = watcher.next() catch continue;
			self.io.sleep(std.Io.Duration.fromMilliseconds(120), .awake) catch {};
			self.reload();
		}
	}

	fn reloadThunk(ctx: *anyopaque) void {
		const self: *Config = @ptrCast(@alignCast(ctx));
		self.reload();
	}

	pub fn reload(self: *Config) void {
		const folder = self.dir(self.allocator);
		defer self.allocator.free(folder);

		const body = configmod.readDir(self.io, self.allocator, folder) catch return;
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
		if (self.changed) |hook| hook.run(hook.ctx);
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
		return error.UnknownMethod;
	}

	fn set(self: *Config, args: json.Value, alloc: Allocator) ![]u8 {
		const name = json.textAt(args, "key");
		const value = json.field(args, "value") orelse return error.NoValue;
		if (name.len == 0) return error.NoKey;

		const folder = self.dir(alloc);
		const list = try configmod.files(self.io, alloc, folder);
		defer {
			for (list) |file| alloc.free(file.body);
			alloc.free(list);
		}

		var found = false;
		var merged: std.ArrayList(u8) = .empty;
		defer merged.deinit(alloc);

		for (list) |file| {
			var body = file.body;
			if (!found and try hasKey(alloc, body, name)) {
				found = true;
				body = try rewrite(alloc, body, name, value);
			}
			const next = try propagate(alloc, body, name, value, 0);
			if (!std.mem.eql(u8, next, file.body)) {
				const path = try std.fmt.allocPrint(alloc, "{s}/{s}.toml", .{ folder, file.name });
				defer alloc.free(path);
				try proc.writeFileAtomic(self.io, alloc, path, next);
			}
			try merged.appendSlice(alloc, next);
			try merged.append(alloc, '\n');
		}

		if (!found) return error.UnknownKey;
		(try configmod.Config.parse(alloc, merged.items)).deinit();
		self.reload();

		return alloc.dupe(u8, "{\"ok\":true}");
	}

	fn get(self: *Config, args: json.Value, alloc: Allocator) ![]u8 {
		const name = json.textAt(args, "key");
		const folder = self.dir(alloc);
		const body = try configmod.readDir(self.io, alloc, folder);
		const cfg = try configmod.Config.parse(alloc, body);
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

const Line = struct {
	key: []const u8 = "",
	comment: []const u8 = "",
	kind: ?Literal = null,
};

fn lines(alloc: Allocator, body: []const u8) ![]Line {
	var out: std.ArrayList(Line) = .empty;
	var depth: i32 = 0;
	var it = std.mem.splitScalar(u8, body, '\n');

	while (it.next()) |raw| {
		const line = std.mem.trim(u8, raw, " \t\r");

		if (depth > 0) {
			depth += brackets(line);
			continue;
		}
		if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;

		const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..eq], " \t");
		var at = eq + 1;
		while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;

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

fn hasKey(alloc: Allocator, body: []const u8, key: []const u8) !bool {
	for (try lines(alloc, body)) |line| {
		if (std.mem.eql(u8, line.key, key)) return true;
	}
	return false;
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
		if (line.comment.len == 0) continue;
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

test "settings.set carries a change into the keys that copy or derive from it" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const body =
		"foreground = \"#ffffff\"\n" ++
		"muted = \"#ffffff\"  # same as foreground\n" ++
		"cpuInk = \"#ffffff\"  # same as muted\n" ++
		"notifyScale = 1.25\n" ++
		"notifyWidth = 350  # Math.round(280 * notifyScale)\n" ++
		"mixerStepCount = 10\n" ++
		"mixerStep = 0.1  # 1 / mixerStepCount\n" ++
		"barFloating = false\n" ++
		"barBorderWidth = 0  # barFloating ? -1 : 0\n";

	const ink = try propagate(a, try rewrite(a, body, "foreground", .{ .string = "#eeeeee" }), "foreground", .{ .string = "#eeeeee" }, 0);
	try std.testing.expect(std.mem.indexOf(u8, ink, "muted = \"#eeeeee\"  # same as foreground") != null);
	try std.testing.expect(std.mem.indexOf(u8, ink, "cpuInk = \"#eeeeee\"") != null);

	const scale = try propagate(a, body, "notifyScale", .{ .float = 1.5 }, 0);
	try std.testing.expect(std.mem.indexOf(u8, scale, "notifyWidth = 420  #") != null);

	const count = try propagate(a, body, "mixerStepCount", .{ .integer = 20 }, 0);
	try std.testing.expect(std.mem.indexOf(u8, count, "mixerStep = 0.05  #") != null);

	const floating = try propagate(a, body, "barFloating", .{ .bool = true }, 0);
	try std.testing.expect(std.mem.indexOf(u8, floating, "barBorderWidth = -1  #") != null);
}
