const std = @import("std");
const hubmod = @import("../hub.zig");
const hypr = @import("../primitives/hypr.zig");
const json = @import("../primitives/json.zig");
const sleep = @import("../primitives/sleep.zig");
const config = @import("../primitives/config.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Hub = hubmod.Hub;

const Mode = struct {
	width: i64,
	height: i64,
	refresh: f64,
};

const Monitor = struct {
	id: i64,
	name: []u8,
	description: []u8,
	make: []u8,
	model: []u8,
	width: i64,
	height: i64,
	refresh: f64,
	x: i64,
	y: i64,
	scale: f64,
	transform: i64,
	focused: bool,
	disabled: bool,
	workspace: []u8,
	modes: std.ArrayListUnmanaged(Mode) = .empty,
};

const ModeOut = struct {
	width: i64,
	height: i64,
	refresh: f64,
	label: []const u8,
};

const ResOut = struct {
	width: i64,
	height: i64,
	label: []const u8,
	maxRefresh: i64,
	refreshes: []ModeOut,
};

const MonitorOut = struct {
	id: i64,
	name: []const u8,
	description: []const u8,
	make: []const u8,
	model: []const u8,
	width: i64,
	height: i64,
	refresh: f64,
	x: i64,
	y: i64,
	scale: f64,
	transform: i64,
	focused: bool,
	disabled: bool,
	workspace: []const u8,
	modes: []ModeOut,
	resolutions: []ResOut,
	scales: []f64,
};

const BorderOut = struct {
	colors: [][]const u8,
	angle: f64,
	width: ?i64,
	strip: StripOut,
};

const StripOut = struct {
	color: []const u8,
	width: i64,
};

const ShadowOut = struct {
	enabled: bool,
	range: i64,
	color: []const u8,
	offsetX: f64,
	offsetY: f64,
	alpha: f64,
	contact: f64,
};

const Shadow = struct {
	enabled: bool,
	range: i64,
	color: []const u8,
	offset_x: f64,
	offset_y: f64,
	alpha: f64,
	contact: f64,
};

const Out = struct {
	border: BorderOut,
	shadow: ShadowOut,
	primary: i64,
	monitors: []MonitorOut,
	raw: []const u8,
};

pub const Screen = struct {
	allocator: Allocator,
	io: Io,
	hub: *Hub,
	mutex: std.Io.Mutex = .init,
	scratch: std.heap.ArenaAllocator,
	monitors: std.ArrayListUnmanaged(Monitor) = .empty,
	raw: []u8 = &.{},
	available: bool = false,
	scale_min: f64 = 1,
	scale_max: f64 = 2,
	border_text: []u8 = &.{},
	border_width: ?i64 = null,
	strip_color: []u8 = &.{},
	strip_width: i64 = 0,
	shadow_enabled: bool = true,
	shadow_range: i64 = 8,
	shadow_color: []u8 = &.{},
	shadow_offset_x: f64 = 0,
	shadow_offset_y: f64 = 2,
	shadow_alpha: f64 = 1,
	shadow_contact: f64 = 0,
	border_tick: usize = 0,

	pub fn create(allocator: Allocator, io: Io, hub: *Hub) !*Screen {
		const self = try allocator.create(Screen);
		self.* = .{
			.allocator = allocator,
			.io = io,
			.hub = hub,
			.scratch = std.heap.ArenaAllocator.init(allocator),
		};

		self.loadConfig();

		return self;
	}

	fn loadConfig(self: *Screen) void {
		const cfg = config.Config.load(self.io, self.allocator) catch return;
		defer cfg.deinit();

		self.scale_min = cfg.number("displayScaleMin", 1);
		self.scale_max = cfg.number("displayScaleMax", 2);
	}

	pub fn provider(self: *Screen) hubmod.Provider {
		return .{ .key = "screen", .ctx = self, .render = renderThunk };
	}

	fn renderThunk(ctx: *anyopaque, writer: *Writer) anyerror!void {
		const self: *Screen = @ptrCast(@alignCast(ctx));
		try self.render(writer);
	}

	pub fn start(self: *Screen) !void {
		const thread = try std.Thread.spawn(.{}, loop, .{self});
		thread.detach();
	}

	fn loop(self: *Screen) void {
		self.poll();

		while (true) {
			sleep.ms(500);
			self.poll();
		}
	}

	fn poll(self: *Screen) void {
		self.border_tick += 1;

		if (self.border_tick % 4 == 0) {
			self.pollBorder();
			self.pollShadow();
		}

		const body = hypr.request(self.io, self.allocator, "j/monitors") catch {
			return;
		};
		defer self.allocator.free(body);

		self.mutex.lockUncancelable(self.io);
		const unchanged = self.raw.len > 0 and std.mem.eql(u8, self.raw, body);
		self.mutex.unlock(self.io);

		if (unchanged) return;

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const parsed = json.parse(arena.allocator(), body) catch return;

		var next: std.ArrayListUnmanaged(Monitor) = .empty;

		for (json.list(parsed.value)) |entry| {
			const mode_list = json.listAt(entry, "availableModes");
			var modes: std.ArrayListUnmanaged(Mode) = .empty;

			for (mode_list) |mode| {
				const label = json.text(mode);
				const parsed_mode = parseMode(label) orelse continue;
				modes.append(self.allocator, parsed_mode) catch continue;
			}

			const workspace = json.field(entry, "activeWorkspace") orelse json.Value{ .null = {} };

			next.append(self.allocator, .{
				.id = json.integer(json.field(entry, "id")),
				.name = self.allocator.dupe(u8, json.textAt(entry, "name")) catch continue,
				.description = self.allocator.dupe(u8, json.textAt(entry, "description")) catch continue,
				.make = self.allocator.dupe(u8, json.textAt(entry, "make")) catch continue,
				.model = self.allocator.dupe(u8, json.textAt(entry, "model")) catch continue,
				.width = json.integer(json.field(entry, "width")),
				.height = json.integer(json.field(entry, "height")),
				.refresh = json.numberAt(entry, "refreshRate"),
				.x = json.integer(json.field(entry, "x")),
				.y = json.integer(json.field(entry, "y")),
				.scale = json.numberAt(entry, "scale"),
				.transform = json.integer(json.field(entry, "transform")),
				.focused = json.flag(entry, "focused"),
				.disabled = json.flag(entry, "disabled"),
				.workspace = self.allocator.dupe(u8, workspaceString(workspace)) catch continue,
				.modes = modes,
			}) catch continue;
		}

		self.mutex.lockUncancelable(self.io);
		self.available = true;
		if (self.raw.len > 0) self.allocator.free(self.raw);
		self.raw = self.allocator.dupe(u8, body) catch &.{};
		for (self.monitors.items) |*monitor| self.freeMonitor(monitor);
		self.monitors.deinit(self.allocator);
		self.monitors = next;
		self.mutex.unlock(self.io);

		self.hub.publish();
	}

	fn pollBorder(self: *Screen) void {
		const option = hypr.request(self.io, self.allocator, "j/getoption general:col.active_border") catch return;
		defer self.allocator.free(option);

		const size = hypr.request(self.io, self.allocator, "j/getoption general:border_size") catch return;
		defer self.allocator.free(size);

		const strip_color = hypr.request(self.io, self.allocator, "j/getoption plugin:borders-plus-plus:col.border_1") catch null;
		defer if (strip_color) |value| self.allocator.free(value);

		const strip_size = hypr.request(self.io, self.allocator, "j/getoption plugin:borders-plus-plus:border_size_1") catch null;
		defer if (strip_size) |value| self.allocator.free(value);

		const strip_count = hypr.request(self.io, self.allocator, "j/getoption plugin:borders-plus-plus:add_borders") catch null;
		defer if (strip_count) |value| self.allocator.free(value);

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const option_value = json.parse(arena.allocator(), option) catch return;
		const size_value = json.parse(arena.allocator(), size) catch return;

		const gradient = json.textAt(option_value.value, "gradient");
		const width = json.integer(json.field(size_value.value, "int"));

		var strip = StripOut{ .color = "#ff000000", .width = 0 };

		if (strip_color != null and strip_size != null and strip_count != null)
			strip = stripFrom(arena.allocator(), strip_color.?, strip_size.?, strip_count.?, width) orelse strip;

		self.mutex.lockUncancelable(self.io);
		const same = std.mem.eql(u8, self.border_text, gradient) and self.border_width == width and self.strip_width == strip.width and std.mem.eql(u8, self.strip_color, strip.color);

		if (!same) {
			self.allocator.free(self.border_text);
			self.border_text = self.allocator.dupe(u8, gradient) catch &.{};
			self.border_width = width;
			self.allocator.free(self.strip_color);
			self.strip_color = self.allocator.dupe(u8, strip.color) catch &.{};
			self.strip_width = strip.width;
		}
		self.mutex.unlock(self.io);

		if (!same) self.hub.publish();
	}

	fn optionValue(self: *Screen, arena: Allocator, name: []const u8) ?json.Value {
		const command = std.fmt.allocPrint(arena, "j/getoption {s}", .{name}) catch return null;
		const body = hypr.request(self.io, self.allocator, command) catch return null;
		defer self.allocator.free(body);

		const parsed = json.parse(arena, body) catch return null;

		return parsed.value;
	}

	fn pluginShadow(self: *Screen, arena: Allocator) ?Shadow {
		const enabled = self.optionValue(arena, "plugin:shadow:enabled") orelse return null;
		if (!json.flag(enabled, "bool")) return null;

		const range = self.optionValue(arena, "plugin:shadow:range") orelse return null;
		const offset = self.optionValue(arena, "plugin:shadow:offset") orelse return null;
		const alpha = self.optionValue(arena, "plugin:shadow:alpha") orelse return null;
		const contact_value = self.optionValue(arena, "plugin:shadow:contact");
		const contact = if (contact_value) |value| json.number(json.field(value, "float")) else 0;
		return .{
			.enabled = true,
			.range = @intFromFloat(@round(json.number(json.field(range, "float")))),
			.color = "rgba(000000ff)",
			.offset_x = 0,
			.offset_y = json.number(json.field(offset, "float")),
			.alpha = std.math.clamp(json.number(json.field(alpha, "float")), 0, 1),
			.contact = std.math.clamp(contact, 0, 1),
		};
	}

	fn decorationShadow(self: *Screen, arena: Allocator) ?Shadow {
		const enabled = self.optionValue(arena, "decoration:shadow:enabled") orelse return null;
		const range = self.optionValue(arena, "decoration:shadow:range") orelse return null;
		const color = self.optionValue(arena, "decoration:shadow:color") orelse return null;
		const offset = self.optionValue(arena, "decoration:shadow:offset") orelse return null;
		const parts = json.listAt(offset, "vec2");

		return .{
			.enabled = json.flag(enabled, "bool"),
			.range = json.integer(json.field(range, "int")),
			.color = gradientColor(arena, json.textAt(color, "gradient")) orelse "rgba(00000070)",
			.offset_x = if (parts.len > 0) json.number(parts[0]) else 0,
			.offset_y = if (parts.len > 1) json.number(parts[1]) else 0,
			.alpha = 1,
			.contact = 0,
		};
	}

	fn pollShadow(self: *Screen) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const shadow = self.pluginShadow(arena.allocator()) orelse self.decorationShadow(arena.allocator()) orelse return;

		self.mutex.lockUncancelable(self.io);
		const same = self.shadow_enabled == shadow.enabled and self.shadow_range == shadow.range and self.shadow_offset_x == shadow.offset_x and self.shadow_offset_y == shadow.offset_y and self.shadow_alpha == shadow.alpha and self.shadow_contact == shadow.contact and std.mem.eql(u8, self.shadow_color, shadow.color);

		if (!same) {
			self.allocator.free(self.shadow_color);
			self.shadow_color = self.allocator.dupe(u8, shadow.color) catch &.{};
			self.shadow_enabled = shadow.enabled;
			self.shadow_range = shadow.range;
			self.shadow_offset_x = shadow.offset_x;
			self.shadow_offset_y = shadow.offset_y;
			self.shadow_alpha = shadow.alpha;
			self.shadow_contact = shadow.contact;
		}
		self.mutex.unlock(self.io);

		if (!same) self.hub.publish();
	}

	fn freeMonitor(self: *Screen, monitor: *Monitor) void {
		self.allocator.free(monitor.name);
		self.allocator.free(monitor.description);
		self.allocator.free(monitor.make);
		self.allocator.free(monitor.model);
		self.allocator.free(monitor.workspace);
		monitor.modes.deinit(self.allocator);
	}

	fn render(self: *Screen, writer: *Writer) !void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		_ = self.scratch.reset(.retain_capacity);
		const arena = self.scratch.allocator();

		var monitors: std.ArrayListUnmanaged(MonitorOut) = .empty;

		for (self.monitors.items) |*monitor| {
			var modes: std.ArrayListUnmanaged(ModeOut) = .empty;

			for (monitor.modes.items) |mode| {
				const label = try std.fmt.allocPrint(arena, "{d}x{d}@{d:.2}", .{ mode.width, mode.height, mode.refresh });
				try modes.append(arena, .{
					.width = mode.width,
					.height = mode.height,
					.refresh = mode.refresh,
					.label = label,
				});
			}

			var resolutions: std.ArrayListUnmanaged(ResOut) = .empty;

			for (monitor.modes.items) |mode| {
				var found: ?*ResOut = null;
				for (resolutions.items) |*res| {
					if (res.width == mode.width and res.height == mode.height) {
						found = res;
						break;
					}
				}

				if (found == null) {
					try resolutions.append(arena, .{ .width = mode.width, .height = mode.height, .label = "", .maxRefresh = 0, .refreshes = &.{} });
					found = &resolutions.items[resolutions.items.len - 1];
				}

				var refreshes: std.ArrayListUnmanaged(ModeOut) = .empty;
				for (found.?.refreshes) |entry| try refreshes.append(arena, entry);
				try refreshes.append(arena, .{
					.width = mode.width,
					.height = mode.height,
					.refresh = mode.refresh,
					.label = try std.fmt.allocPrint(arena, "{d} Hz", .{@as(i64, @intFromFloat(@round(mode.refresh)))}),
				});
				std.mem.sort(ModeOut, refreshes.items, {}, byRefreshDesc);
				found.?.refreshes = refreshes.items;
			}

			var scales: std.ArrayListUnmanaged(f64) = .empty;
			const scale_steps = [_]f64{ 1.0, 1.25, 1.33, 1.5, 1.75, 2.0 };

			for (scale_steps) |value| {
				if (value < self.scale_min or value > self.scale_max) continue;
				try scales.append(arena, value);
			}

			var max_refresh: f64 = 0;
			for (monitor.modes.items) |mode| {
				if (mode.width == monitor.width and mode.height == monitor.height and mode.refresh > max_refresh) max_refresh = mode.refresh;
			}

			for (resolutions.items) |*res| {
				res.label = try std.fmt.allocPrint(arena, "{d}x{d}", .{ res.width, res.height });
				res.maxRefresh = @intFromFloat(@round(res.refreshes[0].refresh));
			}

			if (max_refresh == 0) max_refresh = monitor.refresh;

			try monitors.append(arena, .{
				.id = monitor.id,
				.name = monitor.name,
				.description = monitor.description,
				.make = monitor.make,
				.model = monitor.model,
				.width = monitor.width,
				.height = monitor.height,
				.refresh = monitor.refresh,
				.x = monitor.x,
				.y = monitor.y,
				.scale = monitor.scale,
				.transform = monitor.transform,
				.focused = monitor.focused,
				.disabled = monitor.disabled,
				.workspace = monitor.workspace,
				.modes = modes.items,
				.resolutions = resolutions.items,
				.scales = scales.items,
			});
		}

		var primary: i64 = 0;
		for (self.monitors.items, 0..) |monitor, i| {
			if (monitor.focused) {
				primary = @intCast(i);
				break;
			}
		}

		const stops = parseStops(arena, self.border_text);
		const strip = StripOut{ .color = if (self.strip_color.len > 0) self.strip_color else "#ff000000", .width = self.strip_width };
		const border = BorderOut{ .colors = stops.colors, .angle = stops.angle, .width = self.border_width, .strip = strip };
		const shadow = ShadowOut{ .enabled = self.shadow_enabled, .range = self.shadow_range, .color = if (self.shadow_color.len > 0) self.shadow_color else "rgba(00000070)", .offsetX = self.shadow_offset_x, .offsetY = self.shadow_offset_y, .alpha = self.shadow_alpha, .contact = self.shadow_contact };

		const out = Out{ .border = border, .shadow = shadow, .primary = primary, .monitors = monitors.items, .raw = self.raw };
		try writer.print("{f}", .{std.json.fmt(out, .{})});
	}
};

fn byRefreshDesc(_: void, a: ModeOut, b: ModeOut) bool {
	return a.refresh > b.refresh;
}

fn workspaceString(workspace: json.Value) []const u8 {
	const name = json.textAt(workspace, "name");
	if (name.len > 0) return name;

	const id = json.integer(json.field(workspace, "id"));
	if (id == 0) return "";

	return std.fmt.allocPrint(std.heap.smp_allocator, "{d}", .{id}) catch "";
}

const Stops = struct {
	colors: [][]const u8,
	angle: f64,
};

fn stripFrom(arena: Allocator, color: []const u8, size: []const u8, count: []const u8, border_width: ?i64) ?StripOut {
	const color_value = json.parse(arena, color) catch return null;
	const size_value = json.parse(arena, size) catch return null;
	const count_value = json.parse(arena, count) catch return null;

	const borders = json.integer(json.field(count_value.value, "int"));
	if (borders <= 0) return .{ .color = "#ff000000", .width = 0 };

	const wanted = json.integer(json.field(size_value.value, "int"));
	const thickness = if (wanted < 0) (border_width orelse 0) else wanted;
	const hex = argbText(arena, json.integer(json.field(color_value.value, "int"))) catch return null;

	return .{ .color = hex, .width = thickness * borders };
}

fn argbText(arena: Allocator, value: i64) ![]const u8 {
	return std.fmt.allocPrint(arena, "#{x:0>8}", .{@as(u32, @truncate(@as(u64, @bitCast(value))))});
}

fn parseStops(arena: Allocator, text: []const u8) Stops {
	var colors: std.ArrayListUnmanaged([]const u8) = .empty;
	var angle: f64 = 0;
	var tokens = std.mem.tokenizeAny(u8, text, " \t\n");

	while (tokens.next()) |token| {
		if (std.mem.endsWith(u8, token, "deg")) {
			angle = std.fmt.parseFloat(f64, token[0 .. token.len - 3]) catch angle;
			continue;
		}

		if ((token.len == 6 or token.len == 8) and isHex(token))
			colors.append(arena, std.fmt.allocPrint(arena, "#{s}", .{token}) catch continue) catch continue;
	}

	return .{ .colors = colors.items, .angle = angle };
}

fn gradientColor(arena: Allocator, text: []const u8) ?[]const u8 {
	var tokens = std.mem.tokenizeScalar(u8, text, ' ');
	const token = tokens.next() orelse return null;
	if (token.len != 8 or !isHex(token)) return null;

	return std.fmt.allocPrint(arena, "rgba({s}{s})", .{ token[2..8], token[0..2] }) catch null;
}

fn isHex(text: []const u8) bool {
	for (text) |byte| {
		if (!std.ascii.isHex(byte)) return false;
	}

	return true;
}

test "gradient colors turn into hypr rgba text" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	try std.testing.expectEqualStrings("rgba(00000070)", gradientColor(arena.allocator(), "70000000 0deg").?);
	try std.testing.expect(gradientColor(arena.allocator(), "nope") == null);
}

fn parseMode(label: []const u8) ?Mode {
	const at = std.mem.indexOfScalar(u8, label, '@') orelse return null;
	const x = std.mem.indexOfScalar(u8, label[0..at], 'x') orelse return null;

	const width = std.fmt.parseInt(i64, label[0..x], 10) catch return null;
	const height_text = label[x + 1 .. at];
	const height = std.fmt.parseInt(i64, height_text, 10) catch return null;

	const refresh_text = label[at + 1 ..];
	const cut = std.mem.indexOfAny(u8, refresh_text, "Hh ") orelse refresh_text.len;
	const refresh = std.fmt.parseFloat(f64, refresh_text[0..cut]) catch return null;

	return .{ .width = width, .height = height, .refresh = refresh };
}

test "modes parse from hyprctl labels" {
	const mode = parseMode("2560x1440@165.00Hz") orelse return error.NoMode;
	try std.testing.expectEqual(@as(i64, 2560), mode.width);
	try std.testing.expectEqual(@as(i64, 1440), mode.height);
	try std.testing.expectApproxEqAbs(@as(f64, 165), mode.refresh, 0.01);
	try std.testing.expect(parseMode("nonsense") == null);
}

test "hyprland border text becomes stops" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const gradient = parseStops(arena.allocator(), "ffa78bfa ffe05252 45deg");
	try std.testing.expectEqual(@as(usize, 2), gradient.colors.len);
	try std.testing.expectEqualStrings("#ffa78bfa", gradient.colors[0]);
	try std.testing.expectEqualStrings("#ffe05252", gradient.colors[1]);
	try std.testing.expectEqual(@as(f64, 45), gradient.angle);

	const solid = parseStops(arena.allocator(), "eeffffff 0deg");
	try std.testing.expectEqual(@as(usize, 1), solid.colors.len);
	try std.testing.expectEqualStrings("#eeffffff", solid.colors[0]);

	const plain = parseStops(arena.allocator(), "rgba(ffffffee)");
	try std.testing.expectEqual(@as(usize, 0), plain.colors.len);
	try std.testing.expectEqual(@as(f64, 0), plain.angle);
}

test "plugin border option becomes a strip" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const strip = stripFrom(arena.allocator(), "{\"int\":4278190080,\"set\":true}", "{\"int\":1}", "{\"int\":1}", 2).?;
	try std.testing.expectEqualStrings("#ff000000", strip.color);
	try std.testing.expectEqual(@as(i64, 1), strip.width);

	const inherited = stripFrom(arena.allocator(), "{\"int\":-1}", "{\"int\":-1}", "{\"int\":2}", 2).?;
	try std.testing.expectEqualStrings("#ffffffff", inherited.color);
	try std.testing.expectEqual(@as(i64, 4), inherited.width);

	const off = stripFrom(arena.allocator(), "{\"int\":4278190080}", "{\"int\":1}", "{\"int\":0}", 2).?;
	try std.testing.expectEqual(@as(i64, 0), off.width);
}
