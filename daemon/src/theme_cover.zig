const std = @import("std");
const proc = @import("primitives/proc.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const width = 2560;
const height = 1440;
const Rgb = struct { r: f32, g: f32, b: f32 };
const Theme = struct {
	surface: Rgb = .{ .r = 0.06, .g = 0.06, .b = 0.06 },
	foreground: Rgb = .{ .r = 1, .g = 1, .b = 1 },
	dim: Rgb = .{ .r = 0.25, .g = 0.25, .b = 0.25 },
	palette: [3]Rgb = undefined,
	palette_len: usize = 0,
	red: Rgb = .{ .r = 1, .g = 0, .b = 0 },
	yellow: Rgb = .{ .r = 1, .g = 1, .b = 0 },
	memory: Rgb = .{ .r = 0.5, .g = 0.5, .b = 0.5 },
	bar: Rgb = .{ .r = 1, .g = 1, .b = 1 },
};
fn hexRgb(value: []const u8) ?Rgb {
	var text = value;
	if (text.len > 0 and text[0] == '#') text = text[1..];
	if (text.len == 8) text = text[2..];
	if (text.len != 6) return null;
	return .{
		.r = @as(f32, @floatFromInt(std.fmt.parseInt(u8, text[0..2], 16) catch return null)) / 255,
		.g = @as(f32, @floatFromInt(std.fmt.parseInt(u8, text[2..4], 16) catch return null)) / 255,
		.b = @as(f32, @floatFromInt(std.fmt.parseInt(u8, text[4..6], 16) catch return null)) / 255,
	};
}
fn loadTheme(allocator: Allocator, io: Io, path: []const u8) !Theme {
	var theme: Theme = .{};
	const body = try proc.readFile(io, allocator, path);
	const palette_keys = [_][]const u8{ "borderFallbackColor", "cpuBase", "memoryBase", "weatherBase", "yellow", "red" };
	var lines = std.mem.splitScalar(u8, body, '\n');
	while (lines.next()) |raw| {
		const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |at| raw[0..at] else raw, " \t\r");
		const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..equals], " \t");
		var value = std.mem.trim(u8, line[equals + 1 ..], " \t");
		if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') continue;
		value = value[1 .. value.len - 1];
		const color = hexRgb(value) orelse continue;
		if (std.mem.eql(u8, key, "surface")) theme.surface = color;
		if (std.mem.eql(u8, key, "foreground")) theme.foreground = color;
		if (std.mem.eql(u8, key, "dim")) theme.dim = color;
		if (std.mem.eql(u8, key, "red")) theme.red = color;
		if (std.mem.eql(u8, key, "yellow")) theme.yellow = color;
		if (std.mem.eql(u8, key, "memoryBase")) theme.memory = color;
		if (std.mem.eql(u8, key, "borderFallbackColor")) theme.bar = color;
		for (palette_keys) |name| {
			if (std.mem.eql(u8, key, name) and theme.palette_len < theme.palette.len) {
				theme.palette[theme.palette_len] = color;
				theme.palette_len += 1;
			}
		}
	}
	if (theme.palette_len == 0) {
		theme.palette[0] = theme.surface;
		theme.palette_len = 1;
	}
	return theme;
}
fn blend(pixels: []u8, x: usize, y: usize, color: Rgb, alpha: f32) void {
	const at = (y * width + x) * 4;
	const channels = [_]f32{ color.r, color.g, color.b };
	for (0..3) |index| {
		const base = @as(f32, @floatFromInt(pixels[at + index])) / 255;
		pixels[at + index] = @intFromFloat(std.math.clamp(base * (1 - alpha) + channels[index] * alpha, 0, 1) * 255);
	}
}
fn rect(pixels: []u8, x0: usize, y0: usize, x1: usize, y1: usize, color: Rgb) void {
	var y = y0;
	while (y < y1 and y < height) : (y += 1) {
		var x = x0;
		while (x < x1 and x < width) : (x += 1) blend(pixels, x, y, color, 1);
	}
}
fn render(allocator: Allocator, theme: Theme) ![]u8 {
	const pixels = try allocator.alloc(u8, width * height * 4);
	const colors = theme.palette[0..theme.palette_len];
	for (0..height) |y| {
		const fy = @as(f32, @floatFromInt(y)) / height;
		for (0..width) |x| {
			const fx = @as(f32, @floatFromInt(x)) / width;
			const wave = 0.5 + 0.5 * @sin((fx * 3.0 + fy * 2.0) * std.math.pi);
			const color = colors[@min(@as(usize, @intFromFloat(wave * @as(f32, @floatFromInt(colors.len)))), colors.len - 1)];
			const glow = 0.35 + 0.65 * (1 - @abs(fx - 0.5) * 1.4) * (1 - fy * 0.6);
			const at = (y * width + x) * 4;
			pixels[at] = @intFromFloat(std.math.clamp(theme.surface.r + color.r * glow * 0.35, 0, 1) * 255);
			pixels[at + 1] = @intFromFloat(std.math.clamp(theme.surface.g + color.g * glow * 0.35, 0, 1) * 255);
			pixels[at + 2] = @intFromFloat(std.math.clamp(theme.surface.b + color.b * glow * 0.35, 0, 1) * 255);
			pixels[at + 3] = 255;
		}
	}
	for (0..52) |y| {
		for (0..width) |x| blend(pixels, x, y, theme.surface, 235.0 / 255.0);
	}
	var x: usize = 28;
	for (0..4) |index| {
		rect(pixels, x, 16, x + 6, 30, if (index == 0) theme.foreground else theme.dim);
		x += 28;
	}
	var right: usize = width - 32;
	for ([_]Rgb{ theme.red, theme.yellow, theme.memory, theme.bar, theme.foreground }) |color| {
		right -= 28;
		rect(pixels, right, 16, right + 18, 34, color);
		right -= 8;
	}
	for (0..width) |line_x| blend(pixels, line_x, 51, theme.dim, 90.0 / 255.0);
	return pixels;
}
fn chunk(allocator: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
	var length: [4]u8 = undefined;
	std.mem.writeInt(u32, &length, @intCast(body.len), .big);
	var crc = std.hash.Crc32.init();
	crc.update(kind);
	crc.update(body);
	try out.appendSlice(allocator, &length);
	try out.appendSlice(allocator, kind);
	try out.appendSlice(allocator, body);
	var sum: [4]u8 = undefined;
	std.mem.writeInt(u32, &sum, crc.final(), .big);
	try out.appendSlice(allocator, &sum);
}
fn encodePng(allocator: Allocator, pixels: []const u8) ![]u8 {
	var raw: std.ArrayList(u8) = .empty;
	try raw.ensureTotalCapacity(allocator, height * (1 + width * 4));
	for (0..height) |y| {
		try raw.append(allocator, 0);
		try raw.appendSlice(allocator, pixels[y * width * 4 .. (y + 1) * width * 4]);
	}
	var window: [std.compress.flate.max_window_len]u8 = undefined;
	var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, 64 * 1024);
	var compress = try std.compress.flate.Compress.init(&compressed.writer, &window, .zlib, std.compress.flate.Compress.Options.level_6);
	try compress.writer.writeAll(raw.items);
	try compress.finish();
	var out: std.ArrayList(u8) = .empty;
	try out.appendSlice(allocator, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
	var header: [13]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 6, 0, 0, 0 };
	std.mem.writeInt(u32, header[0..4], width, .big);
	std.mem.writeInt(u32, header[4..8], height, .big);
	try chunk(allocator, &out, "IHDR", &header);
	try chunk(allocator, &out, "IDAT", compressed.written());
	try chunk(allocator, &out, "IEND", &.{});
	return out.toOwnedSlice(allocator);
}
pub fn main() !void {
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();
	var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
	const io = threaded.io();
	const args = try proc.args(io, allocator);
	const repo = proc.repo(io, allocator);
	const plugins = try std.fmt.allocPrint(allocator, "{s}/plugins", .{repo});
	var force = false;
	var ids: std.ArrayList([]const u8) = .empty;
	for (args[1..]) |arg| {
		if (std.mem.eql(u8, arg, "--force")) force = true else try ids.append(allocator, arg);
	}
	if (ids.items.len == 0) {
		var dir = try std.Io.Dir.cwd().openDir(io, plugins, .{ .iterate = true });
		defer dir.close(io);
		var iterator = dir.iterate();
		while (try iterator.next(io)) |entry| {
			if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '_') continue;
			if (!proc.exists(io, try std.fmt.allocPrint(allocator, "{s}/{s}/theme.toml", .{ plugins, entry.name }))) continue;
			try ids.append(allocator, try allocator.dupe(u8, entry.name));
		}
		std.mem.sort([]const u8, ids.items, {}, struct {
			fn lessThan(_: void, a: []const u8, b: []const u8) bool {
				return std.mem.order(u8, a, b) == .lt;
			}
		}.lessThan);
	}
	for (ids.items) |id| {
		const theme_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins, id });
		const theme_path = try std.fmt.allocPrint(allocator, "{s}/theme.toml", .{theme_dir});
		if (!proc.exists(io, theme_path)) {
			std.debug.print("skip {s}: no theme.toml\n", .{id});
			continue;
		}
		const cover = try std.fmt.allocPrint(allocator, "{s}/cover.png", .{theme_dir});
		const jpg = try std.fmt.allocPrint(allocator, "{s}/cover.jpg", .{theme_dir});
		if (!force and (proc.exists(io, cover) or proc.exists(io, jpg))) {
			std.debug.print("skip {s}: cover exists\n", .{id});
			continue;
		}
		const png = try encodePng(allocator, try render(allocator, try loadTheme(allocator, io, theme_path)));
		// ponytail: palette gradient, not the wallpaper; add a decoder when the wallpaper renderer lands.
		try proc.writeFileAtomic(io, allocator, cover, png);
		std.debug.print("plugins/{s}/cover.png {d}K\n", .{ id, png.len / 1024 });
	}
}
