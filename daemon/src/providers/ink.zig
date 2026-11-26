const std = @import("std");
const hubmod = @import("../hub.zig");
const json = @import("../primitives/json.zig");
const proc = @import("../primitives/proc.zig");
const hypr = @import("../primitives/hypr.zig");
const sock = @import("../primitives/sock.zig");
const sleep = @import("../primitives/sleep.zig");
const watch = @import("../primitives/watch.zig");
const configmod = @import("../primitives/config.zig");
const wayland = @import("../primitives/wayland.zig");
const plugins = @import("plugins.zig");
const wallpaper = @import("wallpaper.zig");
const stills = @import("stills.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Hub = hubmod.Hub;

const state_file = "dotfiles/shell/cache/bar-ink.json";
const guest_state = "/run/yudae-state";
const black_ink = "#000000";
const white_ink = "#ffffff";
const fade_shader = "void main() { color = vec4(mix(texture(old, uv).rgb, texture(new, uv).rgb, progress), 1.0); }\n";
const default_fade_ms = 400;

const State = struct {
	bare: bool,
	band: i64,
};

/// How a wallpaper change is drawn: `none`, the built-in `fade`, or a `transition` plugin.
pub const Plan = struct {
	shader: ?[:0]const u8 = null,
	duration_ms: i64 = 0,
	easing: [4]f32 = .{ 0.25, 0.1, 0.25, 1.0 },
	ink_at: f32 = 0.5,
	names: []const [:0]const u8 = &.{},
	values: []const f32 = &.{},
};

pub const Ink = struct {
	allocator: Allocator,
	io: Io,
	hub: *Hub,
	mutex: std.Io.Mutex = .init,
	bare: bool = false,
	band: i64 = 0,
	inks: std.StringHashMapUnmanaged([]u8) = .empty,
	wallpaper: ?*wallpaper.Wallpaper = null,
	stills: ?*stills.Stills = null,
	changed: ?stills.Hook = null,
	running: bool = false,
	paused: bool = false,
	guest: bool = false,
	shared: std.atomic.Value(u64) = .init(0),

	pub fn create(allocator: Allocator, io: Io, hub: *Hub) !*Ink {
		const self = try allocator.create(Ink);
		self.* = .{
			.allocator = allocator,
			.io = io,
			.hub = hub,
		};

		return self;
	}

	pub fn provider(self: *Ink) hubmod.Provider {
		return .{ .key = "ink", .ctx = self, .render = renderThunk };
	}

	fn renderThunk(ctx: *anyopaque, writer: *Writer) anyerror!void {
		const self: *Ink = @ptrCast(@alignCast(ctx));
		try self.render(writer);
	}

	pub fn attach(self: *Ink, source: *wallpaper.Wallpaper) void {
		self.wallpaper = source;
	}

	pub fn start(self: *Ink) !void {
		self.load();

		self.running = wayland.start(self, onEvent);
		if (!self.running) {
			std.debug.print("yudaemond: wallpaper renderer did not start\n", .{});
			return;
		}

		const watcher = try std.Thread.spawn(.{}, pauseLoop, .{self});
		watcher.detach();

		self.guest = inGuest(self.io, self.allocator);
		if (self.guest) {
			const follower = try std.Thread.spawn(.{}, followLoop, .{self});
			follower.detach();
			return;
		}

		const source = self.wallpaper orelse return;

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const path = source.activePath(arena.allocator()) orelse return;
		self.show(arena.allocator(), path, .{});
	}

	pub fn set(self: *Ink, band: i64, bare: ?bool) void {
		self.mutex.lockUncancelable(self.io);
		const changed = band > 0 and self.band != band;
		if (band > 0) self.band = band;
		if (bare) |flag| self.bare = flag;
		self.mutex.unlock(self.io);

		self.persist();
		self.hub.publish();

		if (changed and self.running) wayland.band(band);
	}

	/// Shows `path` on every output with the named transition; an empty name takes the configured one.
	pub fn apply(self: *Ink, path: []const u8, band: i64, transition: []const u8, fade: bool, output: []const u8) void {
		if (path.len == 0) return;

		self.mutex.lockUncancelable(self.io);
		if (band > 0) self.band = band;
		self.mutex.unlock(self.io);

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const allocator = arena.allocator();

		const id = if (!fade) "none" else if (transition.len > 0) transition else configured(self.io, allocator);
		self.showOn(allocator, path, planFor(self.io, allocator, id), output);
	}

	fn show(self: *Ink, allocator: Allocator, path: []const u8, plan: Plan) void {
		self.showOn(allocator, path, plan, "");
	}

	fn showOn(self: *Ink, allocator: Allocator, path: []const u8, plan: Plan, output: []const u8) void {
		if (!self.running) return;

		self.mutex.lockUncancelable(self.io);
		const band = self.band;
		self.mutex.unlock(self.io);

		var req: wayland.Request = .{
			.path = allocator.dupeSentinel(u8, path, 0) catch return,
			.output = if (output.len > 0) (allocator.dupeSentinel(u8, output, 0) catch return).ptr else null,
			.shader = if (plan.shader) |s| s.ptr else null,
			.duration_ms = @intCast(std.math.clamp(plan.duration_ms, 0, 10000)),
			.bezier = plan.easing,
			.ink_at = plan.ink_at,
			.band = @intCast(std.math.clamp(band, 0, 4096)),
		};

		if (self.stills) |store| store.setActive(path);
		if (wayland.isVideo(req.path)) {
			const video = videoPlan(self.io, allocator, path, self.stills);
			req.loop = @intFromBool(video.loop);
			req.still = video.still;
			req.settle_ms = video.settle_ms;
			req.curve = video.curve;
			req.audio = @intFromBool(video.audio);
			req.volume = video.volume;
		}

		const count = @min(plan.names.len, wayland.max_opts);
		for (0..count) |index| {
			req.opt_names[index] = plan.names[index].ptr;
			req.opt_vals[index] = plan.values[index];
		}
		req.n_opts = @intCast(count);

		wayland.apply(&req);
	}

	/// The wallpaper list changed: analyse any video that has no still frame pick yet.
	pub fn rescanned(ctx: *anyopaque) void {
		const self: *Ink = @ptrCast(@alignCast(ctx));
		const source = self.wallpaper orelse return;
		const store = self.stills orelse return;

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const list = source.paths(arena.allocator()) catch return;
		store.scan(list);
	}

	/// `filmstrip {path}` writes keyframe thumbnails once per file version; `preview {path, t}`
	/// writes the exact frame at `t`. Both answer with file paths the settings page shows.
	pub fn call(self: *Ink, method: []const u8, args: json.Value, alloc: Allocator) ![]u8 {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();

		if (std.mem.eql(u8, method, "stats")) {
			const st = wayland.stats();
			const modes = [_][]const u8{ "off", "pending", "playing", "still" };
			const mode = modes[@intCast(std.math.clamp(st.mode, 0, 3))];
			return std.fmt.allocPrint(alloc, "{{\"commits\":{d},\"decoded\":{d},\"presented\":{d},\"dropped\":{d},\"settles\":{d},\"landedErrorMs\":{d},\"video\":\"{s}\",\"paused\":{},\"gl\":{},\"position\":{d},\"running\":{},\"guest\":{}}}", .{
				st.commits, st.decoded, st.presented, st.dropped, st.settles, st.landed_error * 1000, mode, st.paused != 0, st.gl != 0, st.position, self.running, self.guest,
			});
		}

		const path = json.textAt(args, "path");
		if (path.len == 0 or !wayland.isVideoName(path)) return error.NotAVideo;
		const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return error.Missing;
		const key = std.hash.Wyhash.hash(@intCast(stat.mtime.nanoseconds & 0x7fffffffffffffff), path);
		const dir = try std.fmt.allocPrint(a, "{s}/.cache/quickshell/wallpaper", .{proc.home(self.io, a)});
		std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
		const source = try a.dupeSentinel(u8, path, 0);

		var out: Writer.Allocating = .init(alloc);
		if (std.mem.eql(u8, method, "filmstrip")) {
			const prefix = try std.fmt.allocPrintSentinel(a, "{s}/{x}-k", .{ dir, key }, 0);
			var times: [32]f64 = undefined;
			const strip = wayland.filmstrip(source, 240, prefix, &times) orelse return error.DecodeFailed;
			const still = if (self.stills) |store| store.get(path).still() else 0;
			try out.writer.print("{{\"fps\":{d},\"duration\":{d},\"still\":{d},\"frames\":[", .{ strip.fps, strip.duration, still });
			for (times[0..strip.count], 0..) |t, index| {
				if (index > 0) try out.writer.writeAll(",");
				try out.writer.print("{{\"t\":{d},\"thumb\":", .{t});
				try json.write(&out.writer, try std.fmt.allocPrint(a, "{s}{d:0>2}.jpg", .{ prefix[0..prefix.len], index }));
				try out.writer.writeAll("}");
			}
			try out.writer.writeAll("]}");
			return out.toOwnedSlice();
		}

		if (std.mem.eql(u8, method, "preview")) {
			const t = @max(0, json.numberAt(args, "t"));
			const ms: u64 = @intFromFloat(t * 1000);
			const dest = try std.fmt.allocPrintSentinel(a, "{s}/{x}-p{d}.jpg", .{ dir, key, ms }, 0);
			if (!proc.exists(self.io, dest) and !wayland.thumb(source, t, 1280, 85, dest)) return error.DecodeFailed;
			try out.writer.writeAll("{\"thumb\":");
			try json.write(&out.writer, dest);
			try out.writer.print(",\"t\":{d}}}", .{t});
			return out.toOwnedSlice();
		}

		return error.UnknownMethod;
	}

	/// Saves `t` as the still frame of `path` (the active wallpaper when empty) and shows it.
	pub fn saveStill(self: *Ink, path: []const u8, t: f64) void {
		if (t < 0) return;
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const target = if (path.len > 0) path else if (self.wallpaper) |source| source.activePath(arena.allocator()) orelse return else return;
		if (self.stills) |store| store.setRest(target, t);
		if (self.changed) |hook| hook.run(hook.ctx);

		const active = if (self.wallpaper) |source| source.activePath(arena.allocator()) else null;
		if (active) |shown| {
			if (std.mem.eql(u8, shown, target)) wayland.still(t);
		}
	}

	fn pauseLoop(self: *Ink) void {
		self.checkPause();
		while (true) {
			self.listenPause();
			sleep.ms(2000);
		}
	}

	fn listenPause(self: *Ink) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const path = hypr.monitorPath(self.io, arena.allocator()) orelse return;

		var buffer: [8192]u8 = undefined;
		var connection = sock.Connection.connect(path, &buffer) catch return;
		defer connection.close();

		while (connection.readLine() catch return) |line| {
			if (!pauseEvent(line)) continue;
			self.checkPause();
		}
	}

	/// Video wallpapers stop drawing, decoding and playing sound while windows cover them.
	fn checkPause(self: *Ink) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const allocator = arena.allocator();

		const cfg = configmod.Config.load(self.io, allocator) catch return;
		const mode = std.meta.stringToEnum(PauseMode, cfg.string("wallpaperPause", allocator) orelse "fullscreen") orelse .fullscreen;

		var paused = false;
		if (mode != .never) {
			const monitors = hypr.request(self.io, allocator, "j/monitors") catch return;
			const workspaces = hypr.request(self.io, allocator, "j/workspaces") catch return;
			paused = shouldPause(allocator, mode, monitors, workspaces);
		}

		if (paused == self.paused) return;
		self.paused = paused;
		if (self.running) wayland.pause(paused);
	}

	fn onEvent(ctx: ?*anyopaque, kind: c_int, output: [*:0]const u8, path: [*:0]const u8, luma: f64) callconv(.c) void {
		_ = path;
		const self: *Ink = @ptrCast(@alignCast(ctx orelse return));
		const name = std.mem.span(output);
		if (name.len == 0) return;

		switch (@as(wayland.Event, @enumFromInt(kind))) {
			.ink => {
				self.paint(name, if (wayland.isBlack(luma)) black_ink else white_ink);
				self.share();
			},
			.gone => self.forget(name),
			.shown => {
				self.share();
				if (self.changed) |hook| hook.run(hook.ctx);
			},
			else => {},
		}
	}

	/// Host only: writes the shown wallpaper, its still image and the per-output ink for VMs to
	/// follow. Runs off the render thread; a newer change supersedes an older write.
	fn share(self: *Ink) void {
		if (self.guest) return;
		const generation = self.shared.fetchAdd(1, .monotonic) + 1;
		const thread = std.Thread.spawn(.{}, writeShare, .{ self, generation }) catch return;
		thread.detach();
	}

	fn writeShare(self: *Ink, generation: u64) void {
		sleep.ms(100);
		if (self.shared.load(.monotonic) != generation) return;

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();

		const source = self.wallpaper orelse return;
		const path = source.activePath(a) orelse return;
		const dir = std.fmt.allocPrint(a, "{s}/yudae-state", .{proc.runtimeDir(self.io, a)}) catch return;
		std.Io.Dir.cwd().createDirPath(self.io, dir) catch return;

		var image: []const u8 = path;
		if (wayland.isVideoName(path)) {
			const still = if (self.stills) |store| store.get(path).still() else 0;
			const src = a.dupeSentinel(u8, path, 0) catch return;
			const dest = std.fmt.allocPrintSentinel(a, "{s}/still.jpg", .{dir}, 0) catch return;
			if (!wayland.thumb(src, still, 3840, 92, dest)) return;
			image = "still.jpg";
		}

		var buffer: Writer.Allocating = .init(a);
		buffer.writer.writeAll("{\"image\":") catch return;
		json.write(&buffer.writer, image) catch return;
		buffer.writer.writeAll(",\"path\":") catch return;
		json.write(&buffer.writer, path) catch return;
		buffer.writer.print(",\"serial\":{d},", .{generation}) catch return;
		self.mutex.lockUncancelable(self.io);
		writeInks(&buffer.writer, a, &self.inks) catch {
			self.mutex.unlock(self.io);
			return;
		};
		self.mutex.unlock(self.io);
		buffer.writer.writeAll("}") catch return;

		const file = std.fmt.allocPrint(a, "{s}/state.json", .{dir}) catch return;
		proc.writeFileAtomic(self.io, self.allocator, file, buffer.written()) catch return;
	}

	/// Guest only: shows what the host shares, with no transition, no video and no measuring. An
	/// explicit `wallpaper.apply` in the guest still draws, so agents can test the renderer there.
	fn followLoop(self: *Ink) void {
		const file = guest_state ++ "/state.json";
		var last: i128 = -1;
		var watcher: ?watch.Watcher = null;
		defer if (watcher) |*w| w.close();
		var fallback = true;

		while (true) {
			if (fallback and !proc.exists(self.io, file)) {
				fallback = false;
				var arena = std.heap.ArenaAllocator.init(self.allocator);
				defer arena.deinit();
				if (self.wallpaper) |source| {
					if (source.activePath(arena.allocator())) |path| self.show(arena.allocator(), path, .{});
				}
			}

			if (watcher == null and proc.exists(self.io, guest_state)) {
				var w = watch.Watcher.init() catch null;
				if (w) |*value| {
					if (value.add(guest_state)) |_| watcher = value.* else |_| value.close();
				}
			}

			if (std.Io.Dir.cwd().statFile(self.io, file, .{})) |stat| {
				if (stat.mtime.nanoseconds != last) {
					last = stat.mtime.nanoseconds;
					self.follow(file);
				}
			} else |_| {}

			// ponytail: virtiofs does not forward host inotify events to the guest, so the watch
			// only shortens the wait; a 2 s stat poll is the floor. Upgrade path: a vsock nudge.
			if (watcher) |*w| {
				if (w.wait(2000)) w.drain();
			} else sleep.ms(2000);
		}
	}

	fn follow(self: *Ink, file: []const u8) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();

		const raw = proc.readFile(self.io, a, file) catch return;
		const parsed = json.parse(a, raw) catch return;
		const image = json.textAt(parsed.value, "image");
		if (image.len == 0) return;
		const shown = if (std.fs.path.isAbsolute(image)) image else std.fmt.allocPrint(a, "{s}/{s}", .{ guest_state, image }) catch return;

		self.mutex.lockUncancelable(self.io);
		self.band = 0;
		self.mutex.unlock(self.io);
		self.show(a, shown, .{});

		const host = hostInk(parsed.value) orelse return;
		const live = outputs(self.io, a) orelse return;
		for (live) |name| self.paint(name, host);
	}

	fn paint(self: *Ink, output: []const u8, colour: []const u8) void {
		self.mutex.lockUncancelable(self.io);
		const changed = put(self.allocator, &self.inks, output, colour);
		self.mutex.unlock(self.io);

		if (!changed) return;

		std.debug.print("yudaemond: ink {s} {s}\n", .{ output, colour });
		self.persist();
		self.hub.publish();
	}

	fn forget(self: *Ink, output: []const u8) void {
		self.mutex.lockUncancelable(self.io);
		const removed = self.inks.fetchRemove(output);
		self.mutex.unlock(self.io);

		const entry = removed orelse return;
		self.allocator.free(entry.key);
		self.allocator.free(entry.value);

		self.persist();
		self.hub.publish();
	}

	fn persist(self: *Ink) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const allocator = arena.allocator();
		const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ proc.home(self.io, self.allocator), state_file }) catch return;

		var buffer: Writer.Allocating = .init(allocator);
		self.render(&buffer.writer) catch return;
		proc.writeFileAtomic(self.io, self.allocator, path, buffer.written()) catch return;
	}

	fn load(self: *Ink) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();

		const allocator = arena.allocator();
		const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ proc.home(self.io, self.allocator), state_file }) catch return;

		const raw = proc.readFile(self.io, allocator, path) catch return;
		const parsed = json.parse(allocator, raw) catch return;
		const state = stateOf(parsed.value);
		const live = outputs(self.io, allocator);

		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		self.bare = state.bare;
		self.band = state.band;

		const inks = json.field(parsed.value, "inks") orelse return;
		if (inks != .object) return;

		var it = inks.object.iterator();
		while (it.next()) |entry| {
			const colour = json.text(entry.value_ptr.*);
			if (!std.mem.eql(u8, colour, black_ink) and !std.mem.eql(u8, colour, white_ink)) continue;
			_ = put(self.allocator, &self.inks, entry.key_ptr.*, colour);
		}

		if (live) |names| _ = prune(self.allocator, &self.inks, names);
	}

	fn render(self: *Ink, writer: *Writer) !void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		try writer.print("{{\"bare\":{s},\"band\":{d},", .{
			if (self.bare) "true" else "false",
			self.band,
		});

		try writeInks(writer, self.allocator, &self.inks);
		try writer.writeAll("}");
	}
};

fn inGuest(io: Io, allocator: Allocator) bool {
	const vendor = proc.readFile(io, allocator, "/sys/class/dmi/id/sys_vendor") catch return false;
	defer allocator.free(vendor);
	return std.mem.indexOf(u8, vendor, "QEMU") != null;
}

/// The host's ink for the guest: every guest output takes the verdict of the host's first output.
fn hostInk(root: json.Value) ?[]const u8 {
	const inks = json.field(root, "inks") orelse return null;
	if (inks != .object) return null;
	var names: std.ArrayListUnmanaged([]const u8) = .empty;
	var buffer: [16][]const u8 = undefined;
	names = .initBuffer(&buffer);
	var it = inks.object.iterator();
	while (it.next()) |entry| names.appendBounded(entry.key_ptr.*) catch break;
	if (names.items.len == 0) return null;
	std.mem.sort([]const u8, names.items, {}, lessThan);
	const colour = json.text(inks.object.get(names.items[0]).?);
	if (std.mem.eql(u8, colour, black_ink)) return black_ink;
	if (std.mem.eql(u8, colour, white_ink)) return white_ink;
	return null;
}

pub const PauseMode = enum { fullscreen, @"any-window", never };

fn pauseEvent(line: []const u8) bool {
	const events = [_][]const u8{ "fullscreen>>", "openwindow>>", "closewindow>>", "movewindow", "workspace", "focusedmon", "activespecial", "changefloatingmode>>", "minimized>>" };
	for (events) |event| {
		if (std.mem.startsWith(u8, line, event)) return true;
	}
	return false;
}

/// True when a workspace on screen covers the wallpaper: one with a fullscreen window, or in
/// `any-window` mode one with any window at all.
fn shouldPause(allocator: Allocator, mode: PauseMode, monitors_raw: []const u8, workspaces_raw: []const u8) bool {
	if (mode == .never) return false;

	const monitors = json.parse(allocator, monitors_raw) catch return false;
	const workspaces = json.parse(allocator, workspaces_raw) catch return false;

	for (json.list(monitors.value)) |monitor| {
		if (json.flag(monitor, "disabled")) continue;

		const shown = [_]i64{
			json.integer(json.field(json.field(monitor, "activeWorkspace") orelse continue, "id")),
			if (json.field(monitor, "specialWorkspace")) |special| json.integer(json.field(special, "id")) else 0,
		};

		for (json.list(workspaces.value)) |workspace| {
			const id = json.integer(json.field(workspace, "id"));
			if (id == 0 or (id != shown[0] and id != shown[1])) continue;

			if (json.flag(workspace, "hasfullscreen")) return true;
			if (mode == .@"any-window" and json.integer(json.field(workspace, "windows")) > 0) return true;
		}
	}

	return false;
}

fn configured(io: Io, allocator: Allocator) []const u8 {
	const cfg = configmod.Config.load(io, allocator) catch return "fade";
	const settings = std.fmt.allocPrint(allocator, "{s}/dotfiles/shell/cache/settings.lua", .{proc.home(io, allocator)}) catch return "fade";
	const body = proc.readFile(io, allocator, settings) catch "";

	if (luaString(body, "wallpaperTransition")) |id| return id;

	return cfg.string("wallpaperTransition", allocator) orelse "fade";
}

pub const Video = struct {
	loop: bool = false,
	audio: bool = false,
	volume: f32 = 0,
	still: f64 = 0,
	settle_ms: c_int = 1200,
	curve: f32 = 3,
};

fn videoPlan(io: Io, allocator: Allocator, path: []const u8, store: ?*stills.Stills) Video {
	const cfg = configmod.Config.load(io, allocator) catch return .{};
	const entry: stills.Entry = if (store) |found| found.get(path) else .{};
	return .{
		.loop = cfg.boolean("wallpaperVideoLoop", false),
		.audio = cfg.boolean("wallpaperAudio", false),
		.volume = @floatCast(std.math.clamp(cfg.number("wallpaperVolume", 0.6), 0, 1)),
		.still = entry.still(),
		.settle_ms = @intCast(entry.settle_ms),
		.curve = @floatCast(entry.curve),
	};
}

fn fadeMs(io: Io, allocator: Allocator) i64 {
	const cfg = configmod.Config.load(io, allocator) catch return default_fade_ms;
	return cfg.integer("wallpaperTransitionMs", default_fade_ms);
}

/// `none` draws the new wallpaper on the next frame; `fade` is built in; any other id is a plugin.
pub fn planFor(io: Io, allocator: Allocator, id: []const u8) Plan {
	if (std.mem.eql(u8, id, "none")) return .{};
	if (!std.mem.eql(u8, id, "fade")) {
		if (plugins.transition(io, allocator, id)) |found| return .{
			.shader = found.shader,
			.duration_ms = found.duration_ms,
			.easing = found.easing,
			.ink_at = found.ink_at,
			.names = found.names,
			.values = found.values,
		};
		std.debug.print("yudaemond: transition {s} not found, using fade\n", .{id});
	}

	return .{ .shader = fade_shader, .duration_ms = fadeMs(io, allocator) };
}

fn luaString(body: []const u8, key: []const u8) ?[]const u8 {
	var at: usize = 0;
	while (std.mem.indexOfPos(u8, body, at, key)) |found| {
		at = found + key.len;
		var index = at;
		while (index < body.len and (body[index] == ' ' or body[index] == '\t')) index += 1;
		if (index >= body.len or body[index] != '=') continue;
		index += 1;
		while (index < body.len and (body[index] == ' ' or body[index] == '\t')) index += 1;
		if (index >= body.len or (body[index] != '"' and body[index] != '\'')) return null;
		const end = std.mem.indexOfScalarPos(u8, body, index + 1, body[index]) orelse return null;
		return body[index + 1 .. end];
	}
	return null;
}

fn put(allocator: Allocator, inks: *std.StringHashMapUnmanaged([]u8), output: []const u8, colour: []const u8) bool {
	if (inks.getPtr(output)) |slot| {
		if (std.mem.eql(u8, slot.*, colour)) return false;
		const copy = allocator.dupe(u8, colour) catch return false;
		allocator.free(slot.*);
		slot.* = copy;
		return true;
	}

	const key = allocator.dupe(u8, output) catch return false;
	const value = allocator.dupe(u8, colour) catch {
		allocator.free(key);
		return false;
	};
	inks.put(allocator, key, value) catch {
		allocator.free(key);
		allocator.free(value);
		return false;
	};
	return true;
}

fn writeInks(writer: *Writer, allocator: Allocator, inks: *const std.StringHashMapUnmanaged([]u8)) !void {
	var keys: std.ArrayListUnmanaged([]const u8) = .empty;
	defer keys.deinit(allocator);

	var it = inks.iterator();
	while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);

	std.mem.sort([]const u8, keys.items, {}, lessThan);

	try writer.writeAll("\"inks\":{");
	for (keys.items, 0..) |key, index| {
		if (index > 0) try writer.writeAll(",");
		try json.write(writer, key);
		try writer.writeAll(":");
		try json.write(writer, inks.get(key).?);
	}

	try writer.writeAll("},\"verdicts\":{");
	for (keys.items, 0..) |key, index| {
		if (index > 0) try writer.writeAll(",");
		try json.write(writer, key);
		try writer.writeAll(":");
		try json.write(writer, if (std.mem.eql(u8, inks.get(key).?, black_ink)) "black" else "white");
	}
	try writer.writeAll("}");
}

fn stateOf(root: json.Value) State {
	return .{
		.bare = json.flag(root, "bare"),
		.band = json.integer(json.field(root, "band")),
	};
}

/// The outputs Hyprland is driving now. Null when the answer is unknown, because a failed query
/// must not be read as "every output is gone" and wipe the cache.
fn outputs(io: Io, allocator: Allocator) ?[][]const u8 {
	const raw = hypr.request(io, allocator, "j/monitors") catch return null;

	return monitorNames(allocator, raw);
}

fn monitorNames(allocator: Allocator, raw: []const u8) ?[][]const u8 {
	const parsed = json.parse(allocator, raw) catch return null;

	var names: std.ArrayListUnmanaged([]const u8) = .empty;

	for (json.list(parsed.value)) |monitor| {
		const name = json.textAt(monitor, "name");
		if (name.len == 0) continue;

		names.append(allocator, name) catch return null;
	}

	if (names.items.len == 0) return null;

	return names.items;
}

fn prune(allocator: Allocator, inks: *std.StringHashMapUnmanaged([]u8), live: []const []const u8) usize {
	var gone: std.ArrayListUnmanaged([]const u8) = .empty;
	defer gone.deinit(allocator);

	var it = inks.keyIterator();
	while (it.next()) |key| {
		for (live) |name| {
			if (std.mem.eql(u8, name, key.*)) break;
		} else gone.append(allocator, key.*) catch return 0;
	}

	for (gone.items) |key| {
		if (inks.fetchRemove(key)) |entry| {
			allocator.free(entry.key);
			allocator.free(entry.value);
		}
	}

	return gone.items.len;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
	return std.mem.lessThan(u8, a, b);
}

test "the stored state keeps the band and the bare flag" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const parsed = try json.parse(arena.allocator(), "{\"bare\":true,\"band\":33}");
	const state = stateOf(parsed.value);

	try std.testing.expect(state.bare);
	try std.testing.expectEqual(@as(i64, 33), state.band);

	const empty = try json.parse(arena.allocator(), "{}");
	try std.testing.expect(!stateOf(empty.value).bare);
}

test "each output keeps its own ink and the snapshot keeps the shell contract" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var inks: std.StringHashMapUnmanaged([]u8) = .empty;
	try std.testing.expect(put(allocator, &inks, "DP-2", white_ink));
	try std.testing.expect(put(allocator, &inks, "DP-1", black_ink));
	try std.testing.expect(!put(allocator, &inks, "DP-1", black_ink));
	try std.testing.expect(put(allocator, &inks, "DP-1", white_ink));

	var buffer: Writer.Allocating = .init(allocator);
	try writeInks(&buffer.writer, allocator, &inks);
	try std.testing.expectEqualStrings("\"inks\":{\"DP-1\":\"#ffffff\",\"DP-2\":\"#ffffff\"},\"verdicts\":{\"DP-1\":\"white\",\"DP-2\":\"white\"}", buffer.written());
}

test "the live outputs come from the hypr monitor list" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const raw = "[{\"name\":\"DP-2\",\"focused\":true},{\"name\":\"eDP-1\",\"focused\":false}]";
	const names = monitorNames(arena.allocator(), raw).?;

	try std.testing.expectEqual(@as(usize, 2), names.len);
	try std.testing.expectEqualStrings("DP-2", names[0]);

	try std.testing.expect(monitorNames(arena.allocator(), "[]") == null);
	try std.testing.expect(monitorNames(arena.allocator(), "not json") == null);
}

test "a stale output is pruned and a live one kept" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const allocator = arena.allocator();

	var inks: std.StringHashMapUnmanaged([]u8) = .empty;
	defer inks.deinit(allocator);

	try inks.put(allocator, try allocator.dupe(u8, "WAYLAND-9"), try allocator.dupe(u8, black_ink));
	try inks.put(allocator, try allocator.dupe(u8, "DP-2"), try allocator.dupe(u8, white_ink));

	const live = [_][]const u8{ "DP-2", "eDP-1" };

	try std.testing.expectEqual(@as(usize, 1), prune(allocator, &inks, &live));
	try std.testing.expect(inks.get("WAYLAND-9") == null);
	try std.testing.expectEqualStrings(white_ink, inks.get("DP-2").?);
}

test "the transition comes from settings first and none skips the shader" {
	try std.testing.expectEqualStrings("wipe", luaString("wallpaperTransition = \"wipe\",", "wallpaperTransition").?);
	try std.testing.expect(luaString("other = 1", "wallpaperTransition") == null);
	try std.testing.expect(planFor(std.testing.io, std.testing.allocator, "none").shader == null);
}

test "a fullscreen window on a shown workspace pauses the video, a hidden one does not" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	const monitors = "[{\"name\":\"DP-1\",\"activeWorkspace\":{\"id\":1},\"specialWorkspace\":{\"id\":0}}]";
	const tiled = "[{\"id\":1,\"windows\":2,\"hasfullscreen\":false},{\"id\":2,\"windows\":1,\"hasfullscreen\":true}]";
	const full = "[{\"id\":1,\"windows\":1,\"hasfullscreen\":true}]";
	const empty = "[{\"id\":1,\"windows\":0,\"hasfullscreen\":false}]";

	try std.testing.expect(!shouldPause(a, .fullscreen, monitors, tiled));
	try std.testing.expect(shouldPause(a, .fullscreen, monitors, full));
	try std.testing.expect(shouldPause(a, .@"any-window", monitors, tiled));
	try std.testing.expect(!shouldPause(a, .@"any-window", monitors, empty));
	try std.testing.expect(!shouldPause(a, .never, monitors, full));

	const special = "[{\"name\":\"DP-1\",\"activeWorkspace\":{\"id\":1},\"specialWorkspace\":{\"id\":-98}}]";
	const scratch = "[{\"id\":1,\"windows\":0,\"hasfullscreen\":false},{\"id\":-98,\"windows\":1,\"hasfullscreen\":false}]";
	try std.testing.expect(shouldPause(a, .@"any-window", special, scratch));
	try std.testing.expect(pauseEvent("fullscreen>>1"));
	try std.testing.expect(!pauseEvent("activelayout>>kb,us"));
}

test "the guest takes the host's first output ink" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const parsed = try json.parse(arena.allocator(), "{\"image\":\"still.jpg\",\"inks\":{\"HDMI-A-1\":\"#ffffff\",\"DP-1\":\"#000000\"}}");
	try std.testing.expectEqualStrings(black_ink, hostInk(parsed.value).?);
	const none = try json.parse(arena.allocator(), "{\"image\":\"a.png\"}");
	try std.testing.expect(hostInk(none.value) == null);
}
