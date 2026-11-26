const std = @import("std");
const hubmod = @import("../hub.zig");
const json = @import("../primitives/json.zig");
const proc = @import("../primitives/proc.zig");
const sleep = @import("../primitives/sleep.zig");
const inhibit = @import("../primitives/inhibit.zig");
const configmod = @import("../primitives/config.zig");
const wayland = @import("../primitives/wayland.zig");
const wallpaper = @import("wallpaper.zig");
const stills = @import("stills.zig");
const exec = @import("../primitives/exec.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Hub = hubmod.Hub;

const Bus = opaque {};
const Message = opaque {};
const Error = opaque {};
const Callback = *const fn (?*Message, ?*anyopaque, ?*Error) callconv(.c) c_int;

extern fn sd_bus_open_system(bus: *?*Bus) c_int;
extern fn sd_bus_flush_close_unref(bus: *Bus) *Bus;
extern fn sd_bus_add_match(bus: *Bus, slot: ?*?*anyopaque, match: [*:0]const u8, callback: Callback, userdata: ?*anyopaque) c_int;
extern fn sd_bus_process(bus: *Bus, ret: ?*?*Message) c_int;
extern fn sd_bus_wait(bus: *Bus, timeout_usec: u64) c_int;
extern fn sd_bus_message_read(message: *Message, signature: [*:0]const u8, ...) c_int;

const lock_match: [*:0]const u8 = "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Session',member='Lock'";
const sleep_match: [*:0]const u8 = "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep',path='/org/freedesktop/login1'";
const why: [*:0]const u8 = "lock the screen first";
const profile_dir = "cache/.shell/lockscreen";
const fallback_dir = "/var/tmp/yudae-lockscreen";
const preview_px = 2560;
const preview_quality = 90;

/// Locks the shell on logind `Lock` and before sleep, and writes the wallpaper profile the lock
/// screen and the greeter both read from `cache/.shell/lockscreen/<machine-id>/profile.json`.
pub const Lockscreen = struct {
	allocator: Allocator,
	io: Io,
	hub: *Hub,
	wallpaper: ?*wallpaper.Wallpaper = null,
	stills: ?*stills.Stills = null,
	locked: std.atomic.Value(bool) = .init(false),
	mutex: std.Io.Mutex = .init,
	profile: []u8 = &.{},
	generation: std.atomic.Value(u64) = .init(0),
	sleep_fd: c_int = -1,

	pub fn create(allocator: Allocator, io: Io, hub: *Hub) !*Lockscreen {
		const self = try allocator.create(Lockscreen);
		self.* = .{ .allocator = allocator, .io = io, .hub = hub };
		return self;
	}

	pub fn provider(self: *Lockscreen) hubmod.Provider {
		return .{ .key = "lockscreen", .ctx = self, .render = renderThunk };
	}

	fn renderThunk(ctx: *anyopaque, writer: *Writer) anyerror!void {
		const self: *Lockscreen = @ptrCast(@alignCast(ctx));
		try writer.print("{{\"locked\":{},\"profile\":", .{self.locked.load(.monotonic)});
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		try writer.writeAll(if (self.profile.len > 0) self.profile else "null");
		try writer.writeAll("}");
	}

	pub fn start(self: *Lockscreen) !void {
		var buffer: [512]u8 = undefined;
		if (self.marker(&buffer, "locked")) |flag| self.locked.store(proc.exists(self.io, flag), .monotonic);
		self.loadProfile();
		const thread = try std.Thread.spawn(.{}, listen, .{self});
		thread.detach();
		self.refresh();
	}

	pub fn lock(self: *Lockscreen) void {
		self.setLocked(true);
	}

	pub fn unlock(self: *Lockscreen) void {
		self.setLocked(false);
	}

	/// The flag in `$XDG_RUNTIME_DIR` outlives a shell or daemon crash, so a restart locks again.
	fn setLocked(self: *Lockscreen, on: bool) void {
		var buffer: [512]u8 = undefined;
		if (self.marker(&buffer, "locked")) |flag| {
			if (on) proc.writeFile(self.io, flag, "locked\n") catch {} else std.Io.Dir.cwd().deleteFile(self.io, flag) catch {};
		}
		if (self.locked.swap(on, .monotonic) != on) self.hub.publish();
	}

	fn marker(_: *Lockscreen, buffer: []u8, what: []const u8) ?[]const u8 {
		const runtime = std.mem.span(std.c.getenv("XDG_RUNTIME_DIR") orelse "/tmp");
		const instance = std.mem.span(std.c.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse "session");
		return std.fmt.bufPrint(buffer, "{s}/yudae-{s}-{s}", .{ runtime, what, instance }) catch null;
	}

	/// Only these verbs run, so a client cannot pass systemctl anything else.
	pub fn power(self: *Lockscreen, verb: []const u8) void {
		const allowed = [_][]const u8{ "suspend", "reboot", "poweroff" };
		for (allowed) |name| {
			if (!std.mem.eql(u8, name, verb)) continue;
			const thread = std.Thread.spawn(.{}, powerThread, .{ self, name }) catch return;
			thread.detach();
			return;
		}
	}

	fn powerThread(self: *Lockscreen, verb: []const u8) void {
		const result = exec.run(self.io, self.allocator, &.{ "systemctl", verb }) catch return;
		result.deinit(self.allocator);
	}

	fn loadProfile(self: *Lockscreen) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();
		const id = machine(self.io, a);
		const dirs = [_][]const u8{
			std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ proc.repo(self.io, a), profile_dir, id }) catch return,
			std.fmt.allocPrint(a, "{s}/{s}", .{ fallback_dir, id }) catch return,
		};
		for (dirs) |dir| {
			const file = std.fmt.allocPrint(a, "{s}/profile.json", .{dir}) catch return;
			const body = proc.readFile(self.io, a, file) catch continue;
			self.publishProfile(body);
			return;
		}
	}

	fn publishProfile(self: *Lockscreen, body: []const u8) void {
		const owned = self.allocator.dupe(u8, body) catch return;
		self.mutex.lockUncancelable(self.io);
		const old = self.profile;
		self.profile = owned;
		self.mutex.unlock(self.io);
		self.allocator.free(old);
		self.hub.publish();
	}

	pub fn refreshThunk(ctx: *anyopaque) void {
		const self: *Lockscreen = @ptrCast(@alignCast(ctx));
		self.refresh();
	}

	/// Rewrites the profile off the caller's thread; a newer call supersedes an older one.
	pub fn refresh(self: *Lockscreen) void {
		const generation = self.generation.fetchAdd(1, .monotonic) + 1;
		const thread = std.Thread.spawn(.{}, write, .{ self, generation }) catch return;
		thread.detach();
	}

	fn onLock(_: ?*Message, userdata: ?*anyopaque, _: ?*Error) callconv(.c) c_int {
		const self: *Lockscreen = @ptrCast(@alignCast(userdata.?));
		self.lock();
		return 0;
	}

	fn onSleep(message: ?*Message, userdata: ?*anyopaque, _: ?*Error) callconv(.c) c_int {
		const self: *Lockscreen = @ptrCast(@alignCast(userdata.?));
		var going: c_int = 0;
		if (sd_bus_message_read(message.?, "b", &going) < 0) return 0;
		if (going != 0) {
			self.lock();
			sleep.ms(700);
			inhibit.release(self.sleep_fd);
			self.sleep_fd = -1;
		} else if (self.sleep_fd < 0) {
			self.sleep_fd = inhibit.take("sleep", why, "delay");
		}
		return 0;
	}

	// ponytail: any session's Lock signal locks this shell; one desktop user per seat is assumed.
	// Upgrade path: match the path of this user's display session from login1.User.Display.
	fn listen(self: *Lockscreen) void {
		var bus: ?*Bus = null;
		if (sd_bus_open_system(&bus) < 0) return;
		defer _ = sd_bus_flush_close_unref(bus.?);
		if (sd_bus_add_match(bus.?, null, lock_match, onLock, self) < 0) return;
		if (sd_bus_add_match(bus.?, null, sleep_match, onSleep, self) < 0) return;
		self.sleep_fd = inhibit.take("sleep", why, "delay");
		while (true) {
			const result = sd_bus_process(bus.?, null);
			if (result < 0) return;
			if (result > 0) continue;
			if (sd_bus_wait(bus.?, std.math.maxInt(u64)) < 0) return;
		}
	}

	fn write(self: *Lockscreen, generation: u64) void {
		sleep.ms(150);
		if (self.generation.load(.monotonic) != generation) return;

		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const a = arena.allocator();

		const cfg = configmod.Config.load(self.io, a) catch return;
		const desktop = if (self.wallpaper) |source| source.activePath(a) orelse "" else "";
		const home = proc.home(self.io, a);
		const lock_src = pick(a, home, cfg.string("lockWallpaper", a) orelse "desktop", desktop, desktop);
		const greeter_src = pick(a, home, cfg.string("greeterWallpaper", a) orelse "lock", desktop, lock_src);

		const id = machine(self.io, a);
		var dir = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ proc.repo(self.io, a), profile_dir, id }) catch return;
		if (!writable(self.io, a, dir)) {
			dir = std.fmt.allocPrint(a, "{s}/{s}", .{ fallback_dir, id }) catch return;
			if (!writable(self.io, a, dir)) {
				std.debug.print("yudaemond: lockscreen profile has no writable folder\n", .{});
				return;
			}
		}

		var keep: std.ArrayListUnmanaged([]const u8) = .empty;
		var out: Writer.Allocating = .init(a);
		out.writer.writeAll("{\"lock\":") catch return;
		self.describe(a, &out.writer, dir, lock_src, false, &keep) catch |err| return report(err);
		out.writer.writeAll(",\"greeter\":") catch return;
		self.describe(a, &out.writer, dir, greeter_src, true, &keep) catch |err| return report(err);
		out.writer.writeAll(",\"users\":") catch return;
		writeUsers(&out.writer, proc.readFileOr(self.io, a, "/etc/passwd")) catch return;
		out.writer.writeAll(",\"sessions\":") catch return;
		self.writeSessions(a, &out.writer) catch return;
		out.writer.writeAll("}") catch return;

		if (self.generation.load(.monotonic) != generation) return;
		const file = std.fmt.allocPrint(a, "{s}/profile.json", .{dir}) catch return;
		proc.writeFileAtomic(self.io, self.allocator, file, out.written()) catch return;
		self.prune(a, dir, keep.items);
		self.publishProfile(out.written());
		std.debug.print("yudaemond: lockscreen profile {s}\n", .{file});
	}

	fn describe(self: *Lockscreen, a: Allocator, w: *Writer, dir: []const u8, src: []const u8, copy: bool, keep: *std.ArrayListUnmanaged([]const u8)) !void {
		const stat = std.Io.Dir.cwd().statFile(self.io, src, .{}) catch {
			try w.writeAll("{\"source\":\"\",\"video\":false}");
			return;
		};
		const video = wayland.isVideoName(src);
		var entry: stills.Entry = .{};
		if (video) {
			if (self.stills) |store| {
				entry = store.get(src);
				if (!entry.analysed) store.scan(&.{src});
			}
		}
		const still = if (video) entry.still() else 0;

		var hasher = std.hash.Wyhash.init(0);
		hasher.update(src);
		hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
		hasher.update(std.mem.asBytes(&stat.size));
		hasher.update(std.mem.asBytes(&still));
		const key = hasher.final();

		var media: []const u8 = src;
		if (copy) {
			const ext = std.fs.path.extension(src);
			const name = try std.fmt.allocPrint(a, "{x}-media{s}", .{ key, ext });
			media = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
			try keep.append(a, name);
			if (!proc.exists(self.io, media)) {
				const part = try std.fmt.allocPrint(a, "{s}.part", .{media});
				std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), part, self.io, .{}) catch return error.CopyFailed;
				std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), media, self.io) catch return error.CopyFailed;
			}
		}

		var first: []const u8 = media;
		var rest: []const u8 = media;
		if (video) {
			first = try self.frame(a, dir, key, "first", src, 0, keep);
			rest = try self.frame(a, dir, key, "still", src, still, keep);
		}

		try w.writeAll("{\"source\":");
		try json.write(w, media);
		try w.print(",\"video\":{},\"still\":{d},\"settleMs\":{d},\"curve\":{d},\"first\":", .{ video, still, entry.settle_ms, entry.curve });
		try json.write(w, first);
		try w.writeAll(",\"rest\":");
		try json.write(w, rest);
		try w.writeAll("}");
	}

	fn frame(self: *Lockscreen, a: Allocator, dir: []const u8, key: u64, what: []const u8, src: []const u8, t: f64, keep: *std.ArrayListUnmanaged([]const u8)) ![]const u8 {
		const name = try std.fmt.allocPrint(a, "{x}-{s}.jpg", .{ key, what });
		try keep.append(a, name);
		const dest = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
		if (proc.exists(self.io, dest)) return dest;
		const source = try a.dupeSentinel(u8, src, 0);
		if (!wayland.thumb(source, t, preview_px, preview_quality, dest)) return "";
		return dest;
	}

	/// Every wayland session entry in name order; the greeter puts its own Hyprland entry first.
	fn writeSessions(self: *Lockscreen, a: Allocator, w: *Writer) !void {
		try w.writeAll("[");
		defer w.writeAll("]") catch {};
		var folder = std.Io.Dir.cwd().openDir(self.io, sessions_dir, .{ .iterate = true }) catch return;
		defer folder.close(self.io);
		var names: std.ArrayListUnmanaged([]const u8) = .empty;
		var it = folder.iterate();
		while (it.next(self.io) catch null) |item| {
			if (std.mem.endsWith(u8, item.name, ".desktop")) try names.append(a, try a.dupe(u8, item.name));
		}
		std.mem.sort([]const u8, names.items, {}, lessText);
		var first = true;
		for (names.items) |name| {
			const body = proc.readFile(self.io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ sessions_dir, name })) catch continue;
			const session = desktopSession(body) orelse continue;
			if (!first) try w.writeAll(",");
			first = false;
			try w.writeAll("{\"name\":");
			try json.write(w, if (session.name.len > 0) session.name else name[0 .. name.len - ".desktop".len]);
			try w.writeAll(",\"exec\":");
			try writeExec(w, session.exec);
			try w.writeAll("}");
		}
	}

	fn prune(self: *Lockscreen, a: Allocator, dir: []const u8, keep: []const []const u8) void {
		var folder = std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return;
		defer folder.close(self.io);
		var it = folder.iterate();
		next: while (it.next(self.io) catch null) |item| {
			if (std.mem.eql(u8, item.name, "profile.json") or std.mem.startsWith(u8, item.name, ".")) continue;
			for (keep) |name| if (std.mem.eql(u8, name, item.name)) continue :next;
			const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, item.name }) catch continue;
			std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
		}
	}
};

const sessions_dir = "/usr/share/wayland-sessions";

const Session = struct { name: []const u8, exec: []const u8 };

/// The greeter lists people who can log in: a regular uid and a shell that is not a refusal.
fn writeUsers(w: *Writer, passwd: []const u8) !void {
	try w.writeAll("[");
	var first = true;
	var lines = std.mem.splitScalar(u8, passwd, '\n');
	while (lines.next()) |line| {
		var fields: [7][]const u8 = undefined;
		var it = std.mem.splitScalar(u8, line, ':');
		var count: usize = 0;
		while (it.next()) |part| : (count += 1) {
			if (count < 7) fields[count] = part;
		}
		if (count < 7) continue;
		const uid = std.fmt.parseInt(u32, fields[2], 10) catch continue;
		if (uid < 1000 or uid >= 65534) continue;
		if (std.mem.indexOf(u8, fields[6], "nologin") != null or std.mem.endsWith(u8, fields[6], "false")) continue;
		if (!first) try w.writeAll(",");
		first = false;
		try w.writeAll("{\"name\":");
		try json.write(w, fields[0]);
		try w.writeAll(",\"home\":");
		try json.write(w, fields[5]);
		try w.writeAll("}");
	}
	try w.writeAll("]");
}

/// The first `Name=` and `Exec=` of a desktop entry; `%f`-style field codes are dropped later.
fn desktopSession(body: []const u8) ?Session {
	var name: []const u8 = "";
	var command: []const u8 = "";
	var lines = std.mem.splitScalar(u8, body, '\n');
	while (lines.next()) |raw| {
		const line = std.mem.trim(u8, raw, " \r\t");
		if (name.len == 0 and std.mem.startsWith(u8, line, "Name=")) name = line[5..];
		if (command.len == 0 and std.mem.startsWith(u8, line, "Exec=")) command = line[5..];
	}
	if (command.len == 0) return null;
	return .{ .name = name, .exec = command };
}

fn writeExec(w: *Writer, command: []const u8) !void {
	try w.writeAll("[");
	var first = true;
	var parts = std.mem.tokenizeAny(u8, command, " \t");
	while (parts.next()) |part| {
		if (part[0] == '%') continue;
		if (!first) try w.writeAll(",");
		first = false;
		try json.write(w, part);
	}
	try w.writeAll("]");
}

fn report(err: anyerror) void {
	std.debug.print("yudaemond: lockscreen profile failed: {s}\n", .{@errorName(err)});
}

/// A read-only repo (a VM's share) sends the profile to `fallback_dir`, which the greeter reads too.
fn writable(io: Io, a: Allocator, dir: []const u8) bool {
	std.Io.Dir.cwd().createDirPath(io, dir) catch return false;
	const probe = std.fmt.allocPrint(a, "{s}/.probe", .{dir}) catch return false;
	proc.writeFile(io, probe, "") catch return false;
	std.Io.Dir.cwd().deleteFile(io, probe) catch {};
	return true;
}

/// The repo is shared with VMs, so each machine keeps its own profile folder.
fn machine(io: Io, a: Allocator) []const u8 {
	const raw = proc.readFile(io, a, "/etc/machine-id") catch return "local";
	const id = std.mem.trim(u8, raw, " \n\r\t");
	return if (id.len == 0) "local" else id;
}

/// `desktop` and an empty value mean the desktop wallpaper, `lock` the lock's own; `~/` is home.
fn pick(a: Allocator, home: []const u8, choice: []const u8, desktop: []const u8, lock: []const u8) []const u8 {
	if (choice.len == 0 or std.mem.eql(u8, choice, "desktop")) return desktop;
	if (std.mem.eql(u8, choice, "lock")) return lock;
	if (std.mem.startsWith(u8, choice, "~/")) return std.fmt.allocPrint(a, "{s}/{s}", .{ home, choice[2..] }) catch choice;
	return choice;
}

test "the lock and greeter wallpaper choices resolve to a path" {
	const a = std.testing.allocator;
	try std.testing.expectEqualStrings("/d.png", pick(a, "/h", "desktop", "/d.png", "/l.mp4"));
	try std.testing.expectEqualStrings("/d.png", pick(a, "/h", "", "/d.png", "/l.mp4"));
	try std.testing.expectEqualStrings("/l.mp4", pick(a, "/h", "lock", "/d.png", "/l.mp4"));
	try std.testing.expectEqualStrings("/x.webm", pick(a, "/h", "/x.webm", "/d.png", "/l.mp4"));
	const expanded = pick(a, "/h", "~/v.mp4", "/d.png", "/l.mp4");
	defer a.free(expanded);
	try std.testing.expectEqualStrings("/h/v.mp4", expanded);
}

fn lessText(_: void, a: []const u8, b: []const u8) bool {
	return std.mem.lessThan(u8, a, b);
}

test "the greeter lists regular users with a login shell" {
	const passwd =
		\\root:x:0:0::/root:/bin/bash
		\\nobody:x:65534:65534::/:/usr/bin/nologin
		\\ana:x:1000:1000::/home/ana:/bin/zsh
		\\svc:x:1001:1001::/srv:/usr/bin/nologin
		\\off:x:1002:1002::/home/off:/bin/false
		\\bo:x:1003:1003::/home/bo:/bin/bash
		\\broken:x
	;
	var out: Writer.Allocating = .init(std.testing.allocator);
	defer out.deinit();
	try writeUsers(&out.writer, passwd);
	try std.testing.expectEqualStrings("[{\"name\":\"ana\",\"home\":\"/home/ana\"},{\"name\":\"bo\",\"home\":\"/home/bo\"}]", out.written());
}

test "a wayland session entry gives its name and argv without field codes" {
	const session = desktopSession("[Desktop Entry]\nName=Sway\nExec=sway --unsupported-gpu %U\nName=Other\n").?;
	try std.testing.expectEqualStrings("Sway", session.name);
	var out: Writer.Allocating = .init(std.testing.allocator);
	defer out.deinit();
	try writeExec(&out.writer, session.exec);
	try std.testing.expectEqualStrings("[\"sway\",\"--unsupported-gpu\"]", out.written());
	try std.testing.expect(desktopSession("Name=x\n") == null);
}
