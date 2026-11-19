const std = @import("std");
const linux = std.os.linux;

pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;

pub const Event = struct {
	path: []const u8,
};

pub const Watcher = struct {
	fd: i32,
	buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,
	pos: usize = 0,
	len: usize = 0,

	pub fn init() !Watcher {
		const fd = linux.inotify_init1(linux.IN.CLOEXEC);
		if (@as(isize, @bitCast(fd)) < 0) return error.WatchInit;
		return .{ .fd = @intCast(fd) };
	}

	pub fn close(self: *Watcher) void {
		_ = linux.close(self.fd);
	}

	pub fn add(self: *Watcher, path: [:0]const u8) !void {
		const mask = linux.IN.CREATE | linux.IN.MODIFY | linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.DELETE | linux.IN.CLOSE_WRITE | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;
		const result = linux.inotify_add_watch(self.fd, path, mask);
		if (@as(isize, @bitCast(result)) < 0) return error.WatchAdd;
	}

	/// True when an event is already queued, so a debounce can tell a burst that is still
	/// arriving from one that has stopped.
	pub fn pending(self: *Watcher) bool {
		if (self.pos < self.len) return true;
		var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
		return linux.poll(&fds, 1, 0) > 0;
	}

	pub fn wait(self: *Watcher, ms: i32) bool {
		var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
		return linux.poll(&fds, 1, ms) > 0;
	}

	pub fn drain(self: *Watcher) void {
		_ = linux.read(self.fd, &self.buffer, self.buffer.len);
		self.pos = 0;
		self.len = 0;
	}

	pub fn next(self: *Watcher) ![]const u8 {
		if (self.pos >= self.len) {
			const count = linux.read(self.fd, &self.buffer, self.buffer.len);
			if (@as(isize, @bitCast(count)) < 0) return error.WatchRead;
			self.pos = 0;
			self.len = count;
		}

		return self.take();
	}

	fn take(self: *Watcher) ![]const u8 {
		const head = @sizeOf(linux.inotify_event);
		if (self.len - self.pos < head) {
			self.pos = self.len;
			return error.WatchShort;
		}

		const event: *align(1) const linux.inotify_event = @ptrCast(&self.buffer[self.pos]);
		const start = self.pos + head;
		const end = @min(self.len, start + event.len);
		self.pos = end;

		return std.mem.sliceTo(self.buffer[start..end], 0);
	}
};

/// A wallpaper daemon writes the ink of every frame it draws while a wallpaper fades. Waiting
/// for the writes to stop reads the frame the fade ended on, never one halfway through it, and
/// the wait is longer than the fade that produces the burst.
pub const quiet_ms = 550;

pub const Debounce = struct {
	last: i64 = 0,
	armed: bool = false,

	pub fn note(self: *Debounce, now: i64) void {
		self.last = now;
		self.armed = true;
	}

	pub fn due(self: *const Debounce, now: i64) bool {
		return self.armed and now - self.last >= quiet_ms;
	}
};

pub fn dirOf(path: []const u8) []const u8 {
	return std.fs.path.dirname(path) orelse ".";
}

pub fn baseOf(path: []const u8) []const u8 {
	return std.fs.path.basename(path);
}

pub fn watchFile(io: Io, allocator: Allocator, path: []const u8, ctx: *anyopaque, callback: *const fn (*anyopaque) void) !void {
	const wanted = try allocator.dupe(u8, baseOf(path));
	defer allocator.free(wanted);

	var watcher = try Watcher.init();
	defer watcher.close();

	const dir_path = dirOf(path);
	const dir = try allocator.allocSentinel(u8, dir_path.len, 0);
	@memcpy(dir, dir_path);
	defer allocator.free(dir);

	try watcher.add(dir);

	while (true) {
		const name = try watcher.next();

		if (name.len > 0 and !std.mem.eql(u8, name, wanted)) continue;

		try io.sleep(std.Io.Duration.fromMilliseconds(120), .awake);
		callback(ctx);
	}
}

test "a burst of ink writes only reads once the fade that made it is over" {
	var debounce: Debounce = .{};

	try std.testing.expect(!debounce.due(1000));

	debounce.note(1000);
	try std.testing.expect(!debounce.due(1016));
	try std.testing.expect(!debounce.due(1400));
	try std.testing.expect(!debounce.due(1549));
	try std.testing.expect(debounce.due(1550));

	debounce.note(1560);
	try std.testing.expect(!debounce.due(1570));
	try std.testing.expect(debounce.due(2110));
}

test "a renamed write is seen even when it shares a read with other events" {
	const proc = @import("proc.zig");
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
	defer allocator.free(dir);
	const file = try std.fmt.allocPrint(allocator, "{s}/config.toml", .{dir});
	defer allocator.free(file);

	var watcher = try Watcher.init();
	defer watcher.close();
	try watcher.add(dir);

	try proc.writeFileAtomic(std.testing.io, allocator, file, "a = 1\n");

	var seen = false;
	while (watcher.pending()) {
		if (std.mem.eql(u8, try watcher.next(), "config.toml")) seen = true;
	}

	try std.testing.expect(seen);
}

test "watch helpers split a path" {
	try std.testing.expectEqualStrings("/a/b", dirOf("/a/b/c"));
	try std.testing.expectEqualStrings("c", baseOf("/a/b/c"));
}
