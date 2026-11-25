const std = @import("std");
const wayland = @import("primitives/wayland.zig");

const Io = std.Io;

const sizes = [_][2]c_int{ .{ 1920, 1080 }, .{ 2560, 1440 }, .{ 3840, 2160 } };

/// `yudae bench wallpaper <file>...`: image decode time per output size, video decode throughput
/// with and without VA-API and whether frames reach GL without a copy.
pub fn run(io: Io, args: []const []const u8) !void {
	if (args.len >= 3 and std.mem.eql(u8, args[1], "--live")) return live(io, args[2], if (args.len >= 4) std.fmt.parseInt(u32, args[3], 10) catch 5 else 5);
	if (args.len < 2) {
		std.debug.print("usage: yudae bench wallpaper <image|video>...\n", .{});
		std.process.exit(2);
	}

	for (args[1..]) |path| {
		const z = try std.heap.smp_allocator.dupeSentinel(u8, path, 0);
		defer std.heap.smp_allocator.free(z);

		if (wayland.isVideo(z)) {
			for ([_]bool{ true, false }) |hw| {
				const result = wayland.benchVideo(z, 240, hw) orelse {
					std.debug.print("{s}  hw={} failed\n", .{ std.fs.path.basename(path), hw });
					continue;
				};
				const rate = @as(f64, @floatFromInt(result.frames)) / @max(result.seconds, 1e-9);
				std.debug.print("{s}  {d}x{d}@{d:.0}  hw={s} zero_copy={s}  {d} frames  {d:.0} fps decode+upload  last frame rgb {d:.1} {d:.1} {d:.1}\n", .{
					std.fs.path.basename(path), result.width, result.height, result.fps,
					if (result.hw != 0) "yes" else "no", if (result.zero_copy != 0) "yes" else "no",
					result.frames, rate, result.mean[0], result.mean[1], result.mean[2],
				});
			}
			if (wayland.probeAudio(io, z)) |audio| {
				std.debug.print("{s}  audio {d} frames in 1s, {d} after cork\n", .{ std.fs.path.basename(path), audio.playing, audio.corked_growth });
			} else {
				std.debug.print("{s}  no audio track or no PipeWire\n", .{std.fs.path.basename(path)});
			}
			const start = Io.Clock.awake.now(io);
			if (wayland.analyse(z)) |pick| {
				const ms = @as(f64, @floatFromInt(start.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / 1e6;
				std.debug.print("{s}  still pick {d:.3}s  settle {d}ms  curve {d}  {d} frames  {d:.0} ms\n", .{ std.fs.path.basename(path), pick.frame, pick.settle_ms, pick.curve, pick.frames, ms });
			}
			continue;
		}

		for (sizes) |size| {
			var best: f64 = std.math.inf(f64);
			var got: [2]c_int = .{ 0, 0 };
			for (0..5) |_| {
				const start = Io.Clock.awake.now(io);
				const dims = wayland.decodeOnce(z, size[0], size[1]) orelse break;
				const ms = @as(f64, @floatFromInt(start.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / 1e6;
				best = @min(best, ms);
				got = dims;
			}
			if (got[0] == 0) {
				std.debug.print("{s}  decode failed\n", .{std.fs.path.basename(path)});
				break;
			}
			std.debug.print("{s}  for {d}x{d}  decoded {d}x{d}  {d:.1} ms\n", .{ std.fs.path.basename(path), size[0], size[1], got[0], got[1], best });
		}
	}
}

fn noop(_: ?*anyopaque, _: c_int, _: [*:0]const u8, _: [*:0]const u8, _: f64) callconv(.c) void {}

fn cpuTicks(io: Io) i64 {
	var buffer: [1024]u8 = undefined;
	const raw = std.Io.Dir.cwd().readFile(io, "/proc/self/stat", &buffer) catch return 0;
	const close = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return 0;
	var fields = std.mem.tokenizeScalar(u8, raw[close + 2 ..], ' ');
	var index: usize = 0;
	var total: i64 = 0;
	while (fields.next()) |field| : (index += 1) {
		if (index == 11 or index == 12) total += std.fmt.parseInt(i64, field, 10) catch 0;
		if (index > 12) break;
	}
	return total;
}

fn rssKb(io: Io) i64 {
	var buffer: [4096]u8 = undefined;
	const raw = std.Io.Dir.cwd().readFile(io, "/proc/self/status", &buffer) catch return 0;
	const at = std.mem.indexOf(u8, raw, "VmRSS:") orelse return 0;
	var fields = std.mem.tokenizeAny(u8, raw[at + 6 ..], " \t\n");
	return std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
}

fn sleepMs(io: Io, ms: i64) void {
	io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// Draws `path` on every output from this process and reports what playing, pausing and
/// settling cost. It adds its own background surface, so run it in a VM or on a spare session.
fn live(io: Io, path: []const u8, seconds: u32) !void {
	const z = try std.heap.smp_allocator.dupeSentinel(u8, path, 0);
	if (!wayland.start(null, noop)) {
		std.debug.print("no wayland\n", .{});
		std.process.exit(1);
	}
	const video = wayland.isVideo(z);
	wayland.apply(&.{ .path = z, .loop = @intFromBool(video), .settle_ms = 1200, .curve = 3 });
	sleepMs(io, 2000);

	const hz = 100.0;
	const a = wayland.stats();
	const cpu_a = cpuTicks(io);
	const start = Io.Clock.awake.now(io);
	sleepMs(io, @as(i64, seconds) * 1000);
	const b = wayland.stats();
	const cpu_b = cpuTicks(io);
	const secs = @as(f64, @floatFromInt(start.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / 1e9;
	const per = struct {
		fn rate(x: c_long, y: c_long, s: f64) f64 {
			return @as(f64, @floatFromInt(y - x)) / s;
		}
	};
	std.debug.print("{s}  {s}: {d:.1} commits/s  {d:.1} decoded/s  {d:.1} presented/s  {d} dropped  cpu {d:.1}%  rss {d} kB\n", .{
		std.fs.path.basename(path), if (video) "playing" else "idle",
		per.rate(a.commits, b.commits, secs), per.rate(a.decoded, b.decoded, secs), per.rate(a.presented, b.presented, secs),
		b.dropped - a.dropped, @as(f64, @floatFromInt(cpu_b - cpu_a)) / hz / secs * 100, rssKb(io),
	});
	if (!video) return;

	wayland.pause(true);
	sleepMs(io, 1000);
	const c = wayland.stats();
	const cpu_c = cpuTicks(io);
	sleepMs(io, 3000);
	const d = wayland.stats();
	std.debug.print("{s}  paused: {d} commits  {d} decoded in 3s  cpu {d:.2}%\n", .{ std.fs.path.basename(path), d.commits - c.commits, d.decoded - c.decoded, @as(f64, @floatFromInt(cpuTicks(io) - cpu_c)) / hz / 3 * 100 });

	wayland.pause(false);
	wayland.settle();
	var waited: u32 = 0;
	while (wayland.stats().settles == d.settles and waited < 120) : (waited += 1) sleepMs(io, 250);
	const e = wayland.stats();
	if (e.settles == d.settles) {
		std.debug.print("{s}  settle did not land\n", .{std.fs.path.basename(path)});
		return;
	}
	sleepMs(io, 500);
	const f = wayland.stats();
	sleepMs(io, 3000);
	const g = wayland.stats();
	std.debug.print("{s}  settled: landed {d:.2} ms from the still frame  then {d} commits  {d} decoded in 3s\n", .{ std.fs.path.basename(path), e.landed_error * 1000, g.commits - f.commits, g.decoded - f.decoded });
}
