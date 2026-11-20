const std = @import("std");
const hubmod = @import("../hub.zig");
const configmod = @import("../primitives/config.zig");
const proc = @import("../primitives/proc.zig");
const watch = @import("../primitives/watch.zig");
const json = @import("../primitives/json.zig");
const exec = @import("../primitives/exec.zig");

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
		if (std.mem.eql(u8, method, "app")) return openApp(self.io, alloc, "settings", json.textAt(args, "pane"));
		return error.UnknownMethod;
	}

	fn set(self: *Config, args: json.Value, alloc: Allocator) ![]u8 {
		const name = json.textAt(args, "key");
		const value = json.field(args, "value") orelse return error.NoValue;
		if (name.len == 0) return error.NoKey;

		const file = self.path(alloc);
		const body = try proc.readFile(self.io, alloc, file);
		const next = try rewrite(alloc, body, name, value);

		(try configmod.Config.parse(alloc, next)).deinit();
		try proc.writeFileAtomic(self.io, alloc, file, next);
		self.reload();

		return alloc.dupe(u8, "{\"ok\":true}");
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
