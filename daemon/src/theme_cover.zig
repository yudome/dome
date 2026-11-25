const std = @import("std");
const proc = @import("primitives/proc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const width = 2560;
const height = 1440;
const low_width = 640;
const low_height = 360;

const Rgb = struct { r: f32, g: f32, b: f32 };

const Theme = struct {
	surface: Rgb = .{ .r = 0.06, .g = 0.06, .b = 0.06 },
	foreground: Rgb = .{ .r = 1, .g = 1, .b = 1 },
	dim: Rgb = .{ .r = 0.25, .g = 0.25, .b = 0.25 },
	palette: [3]Rgb = .{ .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 0, .g = 0, .b = 0 } },
	palette_len: usize = 0,
	red: Rgb = .{ .r = 1, .g = 0, .b = 0 },
	yellow: Rgb = .{ .r = 1, .g = 1, .b = 0 },
	memory: Rgb = .{ .r = 0.5, .g = 0.5, .b = 0.5 },
	bar_fallback: Rgb = .{ .r = 1, .g = 1, .b = 1 },
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

fn stripComment(line: []const u8) []const u8 {
	var quoted = false;
	for (line, 0..) |char, index| {
		if (char == '"') quoted = !quoted;
		if (char == '#' and !quoted) return line[0..index];
	}
	return line;
}

fn loadTheme(allocator: Allocator, io: Io, path: []const u8) !Theme {
	const body = try proc.readFile(io, allocator, path);
	var theme: Theme = .{};
	var section: []const u8 = "";

	var lines = std.mem.splitScalar(u8, body, '\n');
	while (lines.next()) |raw| {
		const line = std.mem.trim(u8, stripComment(raw), " \t\r");
		if (line.len == 0) continue;
		if (line[0] == '[' and line[line.len - 1] == ']') {
			section = line[1 .. line.len - 1];
			continue;
		}
		const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..equals], " \t");
		var value = std.mem.trim(u8, line[equals + 1 ..], " \t");
		if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') continue;
		value = value[1 .. value.len - 1];
		const color = hexRgb(value) orelse continue;

		if (std.mem.eql(u8, section, "colors")) {
			if (std.mem.eql(u8, key, "surface")) theme.surface = color;
			if (std.mem.eql(u8, key, "foreground")) theme.foreground = color;
			if (std.mem.eql(u8, key, "dim")) theme.dim = color;
			if (std.mem.eql(u8, key, "red")) theme.red = color;
			if (std.mem.eql(u8, key, "yellow")) theme.yellow = color;
		}
		if (std.mem.eql(u8, key, "borderFallbackColor")) theme.bar_fallback = color;
		if (std.mem.eql(u8, key, "memoryBase")) theme.memory = color;

		const palette_keys = [_][]const u8{ "borderFallbackColor", "cpuBase", "memoryBase", "weatherBase", "yellow", "red" };
		var known = false;
		for (palette_keys) |name| {
			if (std.mem.eql(u8, key, name)) known = true;
		}
		if (known and theme.palette_len < 3) {
			theme.palette[theme.palette_len] = color;
			theme.palette_len += 1;
		}
	}
	return theme;
}

fn sampleGrid(grid: []const f32, columns: usize, rows: usize, x: f32, y: f32) f32 {
	const gx = std.math.clamp(x, 0, @as(f32, @floatFromInt(columns - 1)));
	const gy = std.math.clamp(y, 0, @as(f32, @floatFromInt(rows - 1)));
	const x0: usize = @intFromFloat(@floor(gx));
	const y0: usize = @intFromFloat(@floor(gy));
	const x1: usize = @min(x0 + 1, @as(usize, columns - 1));
	const y1: usize = @min(y0 + 1, @as(usize, rows - 1));
	const fx = gx - @as(f32, @floatFromInt(x0));
	const fy = gy - @as(f32, @floatFromInt(y0));

	const top = grid[y0 * columns + x0] * (1 - fx) + grid[y0 * columns + x1] * fx;
	const bottom = grid[y1 * columns + x0] * (1 - fx) + grid[y1 * columns + x1] * fx;
	return top * (1 - fy) + bottom * fy;
}

fn smoothNoise(rng: *std.Random.DefaultPrng, allocator: Allocator, field: []f32) !void {
	@memset(field, 0);
	var weight: f32 = 1;
	var total: f32 = 0;
	var cells: usize = 4;
	const random = rng.random();

	for (0..3) |_| {
		const rows = @max(2, cells * low_height / low_width);
		const grid = try allocator.alloc(f32, rows * cells);
		defer allocator.free(grid);
		for (grid) |*value| value.* = random.float(f32);

		for (0..low_height) |y| {
			const sy = if (low_height == 1) 0 else @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(low_height - 1)) * @as(f32, @floatFromInt(rows - 1));
			for (0..low_width) |x| {
				const sx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(low_width - 1)) * @as(f32, @floatFromInt(cells - 1));
				field[y * low_width + x] += weight * sampleGrid(grid, cells, rows, sx, sy);
			}
		}
		total += weight;
		weight *= 0.45;
		cells *= 2;
	}
	for (field) |*value| value.* /= total;
}

fn render(allocator: Allocator, theme: Theme, name: []const u8) ![]u8 {
	var digest: [32]u8 = undefined;
	std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
	var seed: u64 = 0;
	for (digest[0..8], 0..) |byte, index| seed |= @as(u64, byte) << @intCast(index * 8);
	var rng: std.Random.DefaultPrng = .init(seed);

	const low = try allocator.alloc(f32, low_width * low_height * 3);
	defer allocator.free(low);
	for (0..low_width * low_height) |index| {
		low[index * 3] = theme.surface.r;
		low[index * 3 + 1] = theme.surface.g;
		low[index * 3 + 2] = theme.surface.b;
	}

	const field = try allocator.alloc(f32, low_width * low_height);
	defer allocator.free(field);

	for (theme.palette[0..theme.palette_len]) |color| {
		try smoothNoise(&rng, allocator, field);
		var minimum = field[0];
		var maximum = field[0];
		for (field) |value| {
			minimum = @min(minimum, value);
			maximum = @max(maximum, value);
		}
		const span = @max(1e-6, maximum - minimum);
		for (field, 0..) |value, index| {
			const normalized = (value - minimum) / span;
			const light = std.math.clamp((normalized - 0.3) / 0.7, 0, 1);
			const glow = std.math.pow(f32, light, 2.2) * 0.45;
			low[index * 3] = 1 - (1 - low[index * 3]) * (1 - glow * color.r);
			low[index * 3 + 1] = 1 - (1 - low[index * 3 + 1]) * (1 - glow * color.g);
			low[index * 3 + 2] = 1 - (1 - low[index * 3 + 2]) * (1 - glow * color.b);
		}
	}

	const pixels = try allocator.alloc(u8, width * height * 4);
	errdefer allocator.free(pixels);
	const random = rng.random();

	for (0..height) |y| {
		const sy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1)) * @as(f32, @floatFromInt(low_height - 1));
		const y0: usize = @intFromFloat(@floor(sy));
		const y1: usize = @min(y0 + 1, @as(usize, low_height - 1));
		const fy = sy - @as(f32, @floatFromInt(y0));
		for (0..width) |x| {
			const sx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1)) * @as(f32, @floatFromInt(low_width - 1));
			const x0: usize = @intFromFloat(@floor(sx));
			const x1: usize = @min(x0 + 1, @as(usize, low_width - 1));
			const fx = sx - @as(f32, @floatFromInt(x0));

			for (0..3) |channel| {
				const top = low[(y0 * low_width + x0) * 3 + channel] * (1 - fx) + low[(y0 * low_width + x1) * 3 + channel] * fx;
				const bottom = low[(y1 * low_width + x0) * 3 + channel] * (1 - fx) + low[(y1 * low_width + x1) * 3 + channel] * fx;
				const value = top * (1 - fy) + bottom * fy + (random.float(f32) - 0.5) * 0.008;
				pixels[(y * width + x) * 4 + channel] = @intFromFloat(std.math.clamp(value, 0, 1) * 255);
			}
			pixels[(y * width + x) * 4 + 3] = 255;
		}
	}

	drawBar(pixels, theme);
	return pixels;
}

fn blend(pixels: []u8, x: usize, y: usize, color: Rgb, alpha: f32) void {
	const at = (y * width + x) * 4;
	const channels = [_]f32{ color.r, color.g, color.b };
	for (0..3) |index| {
		const base = @as(f32, @floatFromInt(pixels[at + index])) / 255;
		pixels[at + index] = @intFromFloat(std.math.clamp(base * (1 - alpha) + channels[index] * alpha, 0, 1) * 255);
	}
}

fn rect(pixels: []u8, x0: usize, y0: usize, x1: usize, y1: usize, color: Rgb, alpha: f32) void {
	var y = y0;
	while (y < y1 and y < height) : (y += 1) {
		var x = x0;
		while (x < x1 and x < width) : (x += 1) blend(pixels, x, y, color, alpha);
	}
}

fn drawBar(pixels: []u8, theme: Theme) void {
	const bar_height = 52;
	for (0..bar_height) |y| {
		for (0..width) |x| blend(pixels, x, y, theme.surface, 235.0 / 255.0);
	}

	var x: usize = 28;
	for (0..4) |index| {
		const ink = if (index == 0) theme.foreground else theme.dim;
		rect(pixels, x, 16, x + 6, 30, ink, 1);
		x += 28;
	}

	const chips = [_]Rgb{ theme.red, theme.yellow, theme.memory, theme.bar_fallback, theme.foreground };
	var right: usize = width - 32;
	for (chips) |color| {
		right -= 28;
		rect(pixels, right, 16, right + 18, 34, color, 1);
		right -= 8;
	}

	for (0..width) |line_x| blend(pixels, line_x, bar_height - 1, theme.dim, 90.0 / 255.0);
}

fn chunk(allocator: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
	var length: [4]u8 = undefined;
	std.mem.writeInt(u32, &length, @intCast(body.len), .big);
	try out.appendSlice(allocator, &length);
	var crc = std.hash.Crc32.init();
	crc.update(kind);
	crc.update(body);
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
	const zlib = try compressed.toOwnedSlice();

	var out: std.ArrayList(u8) = .empty;
	try out.appendSlice(allocator, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
	var header: [13]u8 = undefined;
	std.mem.writeInt(u32, header[0..4], width, .big);
	std.mem.writeInt(u32, header[4..8], height, .big);
	header[8] = 8;
	header[9] = 6;
	header[10] = 0;
	header[11] = 0;
	header[12] = 0;
	try chunk(allocator, &out, "IHDR", &header);
	try chunk(allocator, &out, "IDAT", zlib);
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
		if (std.mem.eql(u8, arg, "--force")) {
			force = true;
		} else {
			try ids.append(allocator, arg);
		}
	}

	if (ids.items.len == 0) {
		var dir = try std.Io.Dir.cwd().openDir(io, plugins, .{ .iterate = true });
		defer dir.close(io);
		var iterator = dir.iterate();
		while (try iterator.next(io)) |entry| {
			if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '_') continue;
			const theme_path = try std.fmt.allocPrint(allocator, "{s}/{s}/theme.toml", .{ plugins, entry.name });
			if (!proc.exists(io, theme_path)) continue;
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

		const cover_png = try std.fmt.allocPrint(allocator, "{s}/cover.png", .{theme_dir});
		const cover_jpg = try std.fmt.allocPrint(allocator, "{s}/cover.jpg", .{theme_dir});
		if (!force and (proc.exists(io, cover_png) or proc.exists(io, cover_jpg))) {
			std.debug.print("skip {s}: cover exists\n", .{id});
			continue;
		}

		const theme = try loadTheme(allocator, io, theme_path);
		// ponytail: the cover samples the theme palette, not the wallpaper;
		// add a jpeg/png decoder here when the wallpaper renderer lands.
		const pixels = try render(allocator, theme, id);
		const png = try encodePng(allocator, pixels);
		try proc.writeFileAtomic(io, allocator, cover_png, png);
		std.debug.print("plugins/{s}/cover.png {d}K\n", .{ id, png.len / 1024 });
	}
}
