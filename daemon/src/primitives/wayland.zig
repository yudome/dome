const std = @import("std");

pub const max_opts = 16;

pub const Event = enum(c_int) { ink = 1, gone = 2, shown = 3, _ };

pub const EventFn = *const fn (ctx: ?*anyopaque, kind: c_int, output: [*:0]const u8, path: [*:0]const u8, luma: f64) callconv(.c) void;

pub const Request = extern struct {
	path: [*:0]const u8,
	output: ?[*:0]const u8 = null,
	shader: ?[*:0]const u8 = null,
	duration_ms: c_int = 0,
	bezier: [4]f32 = .{ 0.25, 0.1, 0.25, 1.0 },
	ink_at: f32 = 0.5,
	band: c_int = 0,
	n_opts: c_int = 0,
	opt_names: [max_opts]?[*:0]const u8 = @splat(null),
	opt_vals: [max_opts]f32 = @splat(0),
	loop: c_int = 0,
	still: f64 = 0,
	settle_ms: c_int = 0,
	curve: f32 = 3,
	audio: c_int = 0,
	volume: f32 = 0,
};

extern fn wr_start(ctx: ?*anyopaque, event: EventFn) c_int;
extern fn wr_apply(req: *const Request) void;
extern fn wr_band(band: c_int) void;
extern fn wr_play() void;
extern fn wr_settle() void;
extern fn wr_pause(paused: c_int) void;
extern fn wr_still(seconds: f64) void;
extern fn wr_settle_pos(u: f64, curve: f64) f64;
extern fn wr_settle_target(now: f64, still: f64, dur: f64, travel: f64) f64;
extern fn wr_bezier(p: *const [4]f32, x: f64) f64;
extern fn wr_band_luma(rgba: [*]const u8, width: c_int, rows: c_int) f64;
extern fn wr_is_black(luma: f64) c_int;
extern fn wr_band_rows(band: c_int, scale120: c_int, height: c_int) c_int;
extern fn wr_cover(iw: c_int, ih: c_int, bw: c_int, bh: c_int, off: *[2]f32, scl: *[2]f32) void;
extern fn wr_jpeg_scale(w: c_int, h: c_int, want_w: c_int, want_h: c_int) c_int;

pub fn start(ctx: ?*anyopaque, event: EventFn) bool {
	return wr_start(ctx, event) == 0;
}

pub fn apply(req: *const Request) void {
	wr_apply(req);
}

pub fn band(rows: i64) void {
	wr_band(@intCast(std.math.clamp(rows, 0, 4096)));
}

pub fn play() void {
	wr_play();
}

pub fn settle() void {
	wr_settle();
}

pub fn pause(paused: bool) void {
	wr_pause(@intFromBool(paused));
}

pub fn still(seconds: f64) void {
	wr_still(seconds);
}

pub fn isBlack(luma: f64) bool {
	return wr_is_black(luma) != 0;
}

test "the ink rule matches awww: white bands want black ink, black bands want white" {
	try std.testing.expect(isBlack(1.0));
	try std.testing.expect(!isBlack(0.0));
	try std.testing.expect(isBlack(0.2));
	try std.testing.expect(!isBlack(0.17));
}

test "the band luma reads only the top rows" {
	const canvas = [_]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
	const top = wr_band_luma(&canvas, 4, 1);
	try std.testing.expectApproxEqAbs(@as(f64, 0.2126), top, 1e-6);
	try std.testing.expect(isBlack(top));
	try std.testing.expectApproxEqAbs(@as(f64, 0.6063), wr_band_luma(&canvas, 4, 2), 1e-6);
	try std.testing.expect(wr_band_luma(&canvas, 4, 0) < 0);
	const blue = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255 };
	try std.testing.expect(!isBlack(wr_band_luma(&blue, 2, 1)));
}

test "the band rows follow the output scale and stay inside the buffer" {
	try std.testing.expectEqual(@as(c_int, 64), wr_band_rows(40, 192, 2304));
	try std.testing.expectEqual(@as(c_int, 40), wr_band_rows(40, 120, 1080));
	try std.testing.expectEqual(@as(c_int, 10), wr_band_rows(40, 120, 10));
	try std.testing.expectEqual(@as(c_int, 0), wr_band_rows(0, 120, 1080));
}

test "cover crops the long side and keeps the centre" {
	var off: [2]f32 = undefined;
	var scl: [2]f32 = undefined;
	wr_cover(3072, 3072, 2560, 1440, &off, &scl);
	try std.testing.expectApproxEqAbs(@as(f32, 1), scl[0], 1e-6);
	try std.testing.expectApproxEqAbs(@as(f32, 0.5625), scl[1], 1e-6);
	try std.testing.expectApproxEqAbs(@as(f32, 0), off[0], 1e-6);
	try std.testing.expectApproxEqAbs(@as(f32, 0.21875), off[1], 1e-6);
	wr_cover(2560, 1440, 2560, 1440, &off, &scl);
	try std.testing.expectApproxEqAbs(@as(f32, 1), scl[0], 1e-6);
	try std.testing.expectApproxEqAbs(@as(f32, 1), scl[1], 1e-6);
}

test "jpeg decode shrinks only while the image still covers the output" {
	try std.testing.expectEqual(@as(c_int, 2), wr_jpeg_scale(7680, 4320, 2560, 1440));
	try std.testing.expectEqual(@as(c_int, 4), wr_jpeg_scale(7680, 4320, 1920, 1080));
	try std.testing.expectEqual(@as(c_int, 1), wr_jpeg_scale(2560, 1440, 2560, 1440));
	try std.testing.expectEqual(@as(c_int, 1), wr_jpeg_scale(1920, 1080, 2560, 1440));
}

test "the easing curve starts at 0, ends at 1 and the ink flips at ink_at" {
	const ease: [4]f32 = .{ 0.25, 0.1, 0.25, 1.0 };
	try std.testing.expectEqual(@as(f64, 0), wr_bezier(&ease, 0));
	try std.testing.expectEqual(@as(f64, 1), wr_bezier(&ease, 1));
	const linear: [4]f32 = .{ 0, 0, 1, 1 };
	try std.testing.expectApproxEqAbs(@as(f64, 0.5), wr_bezier(&linear, 0.5), 1e-6);
	var prev: f64 = 0;
	var flipped: ?usize = null;
	for (0..101) |i| {
		const p = wr_bezier(&ease, @as(f64, @floatFromInt(i)) / 100);
		try std.testing.expect(p >= prev - 1e-9);
		if (flipped == null and p >= 0.5) flipped = i;
		prev = p;
	}
	try std.testing.expect(flipped.? > 20 and flipped.? < 50);
}

extern fn wr_check_shader(src: [*:0]const u8, err: [*]u8, len: c_int) c_int;

/// Compiles a transition shader body with the renderer's header on the real driver.
pub fn checkShader(src: [*:0]const u8, err: []u8) bool {
	return wr_check_shader(src, err.ptr, @intCast(err.len)) == 0;
}

pub const VideoBench = extern struct {
	frames: c_int,
	seconds: f64,
	hw: c_int,
	zero_copy: c_int,
	width: c_int,
	height: c_int,
	fps: f64,
	mean: [3]f64,
};

const Image = extern struct { px: ?[*]u8, w: c_int, h: c_int };

extern fn wr_bench_video(path: [*:0]const u8, frames: c_int, hw: c_int, out: *VideoBench) c_int;
extern fn wr_decode(path: [*:0]const u8, want_w: c_int, want_h: c_int, out: *Image) c_int;
extern fn wr_image_free(img: *Image) void;
extern fn wr_is_video(path: [*:0]const u8) c_int;

pub fn isVideoName(path: []const u8) bool {
	const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
	for ([_][]const u8{ ".mp4", ".webm", ".mkv", ".mov" }) |ext| {
		if (std.ascii.eqlIgnoreCase(path[dot..], ext)) return true;
	}
	return false;
}

pub fn isVideo(path: [*:0]const u8) bool {
	return wr_is_video(path) != 0;
}

pub fn benchVideo(path: [*:0]const u8, frames: c_int, hw: bool) ?VideoBench {
	var out: VideoBench = undefined;
	if (wr_bench_video(path, frames, @intFromBool(hw), &out) != 0) return null;
	return out;
}

/// Decodes once the way the renderer does for an output of `w`x`h`; returns the decoded size.
pub fn decodeOnce(path: [*:0]const u8, w: c_int, h: c_int) ?[2]c_int {
	var img: Image = undefined;
	if (wr_decode(path, w, h, &img) != 0) return null;
	defer wr_image_free(&img);
	return .{ img.w, img.h };
}

test "the settle ramp starts at full speed and lands exactly on the still frame" {
	for ([_]f64{ 2, 3, 4 }) |curve| {
		try std.testing.expectEqual(@as(f64, 0), wr_settle_pos(0, curve));
		try std.testing.expectEqual(@as(f64, 1), wr_settle_pos(1, curve));
		const h = 1e-6;
		const start_rate = wr_settle_pos(h, curve) / h / curve;
		try std.testing.expectApproxEqAbs(@as(f64, 1), start_rate, 1e-4);
		const end_rate = (1 - wr_settle_pos(1 - h, curve)) / h / curve;
		try std.testing.expect(end_rate < 1e-3);
	}
}

test "the settle target is the next still frame far enough ahead, looping forward" {
	try std.testing.expectEqual(@as(f64, 4), wr_settle_target(1, 4, 10, 0.4));
	try std.testing.expectEqual(@as(f64, 14), wr_settle_target(3.8, 4, 10, 0.4));
	try std.testing.expectEqual(@as(f64, 24), wr_settle_target(13.9, 4, 10, 0.4));
	try std.testing.expectEqual(@as(f64, 4), wr_settle_target(0, 4, 10, 4));
	try std.testing.expect(wr_settle_target(7, 4, 10, 0.4) >= 7.4);
}

extern fn wr_thumb(path: [*:0]const u8, seconds: f64, px: c_int, quality: c_int, dest: [*:0]const u8) c_int;

/// Writes a JPEG of `path` (a video frame at `seconds`) that fits in `px` x `px`.
pub fn thumb(path: [*:0]const u8, seconds: f64, px: c_int, quality: c_int, dest: [*:0]const u8) bool {
	return wr_thumb(path, seconds, px, quality, dest) == 0;
}

pub const FrameStats = extern struct { motion: f32, sharp: f32, bright: f32, contrast: f32, top: f32 };
pub const Pick = extern struct { frame: f64, settle_ms: c_int, curve: f32, frames: c_int, top: f32 };

extern fn wr_pick_index(stats: [*]const FrameStats, n: c_int, fps: f64, settle_ms: *c_int, curve: *f32) c_int;
extern fn wr_analyze(path: [*:0]const u8, out: *Pick) c_int;

/// Decodes the whole video at 160x90 and picks the frame it should settle on.
pub fn analyse(path: [*:0]const u8) ?Pick {
	var out: Pick = undefined;
	if (wr_analyze(path, &out) != 0) return null;
	return out;
}

test "the still pick lands where motion decays, away from cuts and dark frames" {
	var frames: [150]FrameStats = undefined;
	for (&frames, 0..) |*s, i| {
		const f: f32 = @floatFromInt(i);
		s.* = .{ .motion = 0.05, .sharp = 0.05, .bright = 0.5, .contrast = 0.2, .top = 0.5 };
		if (i < 30) s.motion = 0.05;
		if (i >= 30 and i < 60) s.motion = 0.05 - (f - 30) * 0.0016;
		if (i >= 60 and i < 90) s.motion = 0.002;
		if (i >= 60 and i < 66) s.sharp = 0.08;
		if (i == 100) s.motion = 0.6;
		if (i >= 100) s.bright = 0.03;
	}
	var settle_ms: c_int = 0;
	var curve: f32 = 0;
	const pick = wr_pick_index(&frames, frames.len, 30, &settle_ms, &curve);
	try std.testing.expect(pick >= 58 and pick <= 66);
	try std.testing.expect(settle_ms >= 600 and settle_ms <= 2500);
	try std.testing.expect(curve >= 2);
}

extern fn wr_filmstrip(path: [*:0]const u8, n: c_int, px: c_int, prefix: [*:0]const u8, times: [*]f64, fps: *f64, duration: *f64) c_int;

pub const Strip = struct { count: usize, fps: f64, duration: f64 };

/// Writes up to `times.len` keyframe thumbnails as `<prefix>NN.jpg`, seeking only to keyframes.
pub fn filmstrip(path: [*:0]const u8, px: c_int, prefix: [*:0]const u8, times: []f64) ?Strip {
	var fps: f64 = 0;
	var duration: f64 = 0;
	const count = wr_filmstrip(path, @intCast(times.len), px, prefix, times.ptr, &fps, &duration);
	if (count < 0) return null;
	return .{ .count = @intCast(count), .fps = fps, .duration = duration };
}

extern fn wr_audio_opens(enabled: c_int, volume: f32) c_int;

test "audio off never opens the track or a stream, whatever the volume" {
	try std.testing.expectEqual(@as(c_int, 0), wr_audio_opens(0, 1));
	try std.testing.expectEqual(@as(c_int, 0), wr_audio_opens(0, 0));
	try std.testing.expectEqual(@as(c_int, 0), wr_audio_opens(1, 0));
	try std.testing.expectEqual(@as(c_int, 1), wr_audio_opens(1, 0.5));
}

extern fn au_start(path: [*:0]const u8, from: f64, volume: f32, fade: f64) c_int;
extern fn au_pause(paused: c_int) void;
extern fn au_stop() void;
extern fn au_delivered() c_long;

pub const AudioProbe = struct { playing: c_long, corked_growth: c_long };

/// Plays the audio track almost silently for a moment, then corks it and checks the stream stops.
pub fn probeAudio(io: std.Io, path: [*:0]const u8) ?AudioProbe {
	if (au_start(path, 0, 0.0001, 0) != 0) return null;
	defer au_stop();
	io.sleep(.fromMilliseconds(1000), .awake) catch {};
	const playing = au_delivered();
	au_pause(1);
	io.sleep(.fromMilliseconds(600), .awake) catch {};
	const corked = au_delivered();
	io.sleep(.fromMilliseconds(600), .awake) catch {};
	return .{ .playing = playing, .corked_growth = au_delivered() - corked };
}

pub const Stats = extern struct {
	commits: c_long,
	decoded: c_long,
	presented: c_long,
	dropped: c_long,
	settles: c_long,
	landed_error: f64,
	mode: c_int,
	paused: c_int,
	gl: c_int,
	position: f64,
};

extern fn wr_get_stats(out: *Stats) void;

pub fn stats() Stats {
	var out: Stats = undefined;
	wr_get_stats(&out);
	return out;
}
