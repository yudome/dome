const std = @import("std");
const linux = std.os.linux;
const index = @import("index.zig");
const build = @import("build.zig");
const proc = @import("../../primitives/proc.zig");

const Allocator = std.mem.Allocator;
pub const recent_cap = 20000;
const watch_cap = 32768;
const watch_depth = 8;

const Fresh = struct {
	path: []u8,
	at: i64,
};

const Watched = struct {
	path: []u8,
	depth: u8,
};

pub const Recent = struct {
	allocator: Allocator,
	io: std.Io,
	home: []u8,
	log: []u8,
	fd: i32 = -1,
	log_fd: i32 = -1,
	mutex: std.Io.Mutex = .init,
	paths: std.ArrayList(Fresh) = .empty,
	known: std.StringHashMapUnmanaged(void) = .empty,
	dirs: std.AutoHashMapUnmanaged(i32, Watched) = .empty,

	pub fn create(allocator: Allocator, io: std.Io, home: []const u8, log: []const u8) !*Recent {
		const self = try allocator.create(Recent);
		errdefer allocator.destroy(self);
		self.* = .{ .allocator = allocator, .io = io, .home = try allocator.dupe(u8, std.mem.trimEnd(u8, home, "/")), .log = try allocator.dupe(u8, log) };
		if (std.fs.path.dirname(log)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
		return self;
	}

	pub fn deinit(self: *Recent) void {
		if (self.fd >= 0) _ = linux.close(self.fd);
		if (self.log_fd >= 0) _ = linux.close(self.log_fd);
		self.allocator.free(self.log);
		var dirs = self.dirs.valueIterator();
		while (dirs.next()) |dir| self.allocator.free(dir.path);
		self.dirs.deinit(self.allocator);
		for (self.paths.items) |fresh| self.allocator.free(fresh.path);
		self.paths.deinit(self.allocator);
		self.known.deinit(self.allocator);
		self.allocator.free(self.home);
	}

	pub fn start(self: *Recent) !void {
		const fd = linux.inotify_init1(linux.IN.CLOEXEC);
		if (linux.errno(fd) != .SUCCESS) return error.WatchInit;
		self.fd = @intCast(fd);
		self.load();
		self.watchTree(self.home, 0);
		(try std.Thread.spawn(.{}, loop, .{self})).detach();
	}

	fn load(self: *Recent) void {
		const body = proc.readFile(self.io, self.allocator, self.log) catch "";
		defer self.allocator.free(body);
		var lines = std.mem.splitScalar(u8, body, '\n');
		while (lines.next()) |line| {
			const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
			const at = std.fmt.parseInt(i64, line[0..space], 10) catch continue;
			self.remember(line[space + 1 ..], at, false);
		}
		self.rewrite();
	}

	pub fn found(self: *Recent, path: []const u8) !bool {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		self.remember(path, std.Io.Clock.real.now(self.io).toMilliseconds(), true);
		return self.paths.items.len < recent_cap;
	}

	fn drop(self: *Recent, at: usize) void {
		const gone = self.paths.orderedRemove(at);
		_ = self.known.remove(gone.path);
		self.allocator.free(gone.path);
	}

	fn remember(self: *Recent, path: []const u8, at: i64, append: bool) void {
		if (self.known.contains(path)) return;
		const owned = self.allocator.dupe(u8, path) catch return;
		if (self.paths.items.len >= recent_cap) self.drop(0);
		self.known.put(self.allocator, owned, {}) catch return self.allocator.free(owned);
		self.paths.append(self.allocator, .{ .path = owned, .at = at }) catch {
			_ = self.known.remove(owned);
			return self.allocator.free(owned);
		};
		if (!append) return;
		var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
		const line = std.fmt.bufPrint(&buf, "{d} {s}\n", .{ at, path }) catch return;
		_ = linux.write(self.log_fd, line.ptr, line.len);
	}

	fn rewrite(self: *Recent) void {
		var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
		const temp = std.fmt.bufPrintSentinel(&buf, "{s}.tmp", .{self.log}, 0) catch return;
		const fd = linux.open(temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
		if (linux.errno(fd) != .SUCCESS) return;
		var line_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
		for (self.paths.items) |fresh| {
			const line = std.fmt.bufPrint(&line_buf, "{d} {s}\n", .{ fresh.at, fresh.path }) catch continue;
			_ = linux.write(@intCast(fd), line.ptr, line.len);
		}
		var log_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
		const log = std.fmt.bufPrintSentinel(&log_buf, "{s}", .{self.log}, 0) catch return;
		if (linux.errno(linux.rename(temp, log)) != .SUCCESS) return;
		if (self.log_fd >= 0) _ = linux.close(self.log_fd);
		self.log_fd = @intCast(fd);
		_ = linux.lseek(self.log_fd, 0, linux.SEEK.END);
	}

	fn watchTree(self: *Recent, path: []const u8, depth: u8) void {
		if (self.dirs.count() >= watch_cap) return;
		var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
		const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
		const wd = linux.inotify_add_watch(self.fd, z, linux.IN.CREATE | linux.IN.MOVED_TO | linux.IN.ONLYDIR);
		if (linux.errno(wd) != .SUCCESS) return;
		const owned = self.allocator.dupe(u8, path) catch return;
		self.mutex.lockUncancelable(self.io);
		const old = self.dirs.fetchPut(self.allocator, @intCast(wd), .{ .path = owned, .depth = depth }) catch null;
		self.mutex.unlock(self.io);
		if (old) |entry| self.allocator.free(entry.value.path);
		if (depth >= watch_depth) return;

		var entries = build.Entries.open(z) orelse return;
		defer entries.close();
		while (entries.next()) |entry| {
			const name = build.nameOf(entry);
			if (entry.type != linux.DT.DIR or name.len == 0 or name[0] == '.' or build.skipName(name)) continue;
			var child_buf: [std.fs.max_path_bytes]u8 = undefined;
			self.watchTree(std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, name }) catch continue, depth + 1);
		}
	}

	fn loop(self: *Recent) void {
		var buffer: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
		while (true) {
			const read = linux.read(self.fd, &buffer, buffer.len);
			if (linux.errno(read) == .INTR) continue;
			if (linux.errno(read) != .SUCCESS or read == 0) return;
			self.handle(buffer[0..read]);
		}
	}

	fn handle(self: *Recent, bytes: []const u8) void {
		var offset: usize = 0;
		while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
			const event: *align(1) const linux.inotify_event = @ptrCast(&bytes[offset]);
			const name_start = offset + @sizeOf(linux.inotify_event);
			offset = name_start + event.len;
			if (event.mask & linux.IN.IGNORED != 0) {
				self.mutex.lockUncancelable(self.io);
				const old = self.dirs.fetchRemove(event.wd);
				self.mutex.unlock(self.io);
				if (old) |entry| self.allocator.free(entry.value.path);
				continue;
			}
			const name = std.mem.sliceTo(bytes[name_start..@min(offset, bytes.len)], 0);
			if (name.len == 0 or name[0] == '.' or build.skipName(name)) continue;
			self.note(event.wd, name, event.mask & linux.IN.ISDIR != 0);
		}
	}

	fn note(self: *Recent, wd: i32, name: []const u8, dir: bool) void {
		var buf: [std.fs.max_path_bytes]u8 = undefined;
		self.mutex.lockUncancelable(self.io);
		const parent = self.dirs.get(wd) orelse return self.mutex.unlock(self.io);
		const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ parent.path, name }) catch return self.mutex.unlock(self.io);
		self.remember(full, std.Io.Clock.real.now(self.io).toMilliseconds(), true);
		self.mutex.unlock(self.io);
		if (dir and parent.depth < watch_depth) self.watchTree(full, parent.depth + 1);
	}

	pub fn search(self: *Recent, arena: Allocator, query: []const u8, out: *std.ArrayList([]const u8)) !void {
		if (query.len == 0 or query.len > 255) return;
		var needle_buf: [256]u8 = undefined;
		var folded: [256]u8 = undefined;
		const needle = index.fold(&needle_buf, query);
		const ascii = index.isAscii(needle);
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		var at = self.paths.items.len;
		while (at > 0) {
			at -= 1;
			const path = self.paths.items[at].path;
			if (index.matches(std.fs.path.basename(path), needle, ascii, &folded)) try out.append(arena, try arena.dupe(u8, path));
		}
	}

	pub fn prune(self: *Recent, before: i64) void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		var kept: usize = 0;
		for (self.paths.items) |fresh| {
			if (fresh.at >= before) {
				self.paths.items[kept] = fresh;
				kept += 1;
				continue;
			}
			_ = self.known.remove(fresh.path);
			self.allocator.free(fresh.path);
		}
		self.paths.shrinkRetainingCapacity(kept);
		self.rewrite();
	}
};

test "recent files show up from inotify before the next rebuild" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);
	const file = try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/e/f/Fresh-Invoice.pdf", .{root});
	defer allocator.free(file);
	try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(file).?);

	const log = try std.fmt.allocPrint(allocator, "{s}/files.log", .{root});
	defer allocator.free(log);
	var recent: Recent = .{ .allocator = allocator, .io = io, .home = try allocator.dupe(u8, root), .log = try allocator.dupe(u8, log) };
	defer recent.deinit();
	recent.fd = @intCast(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK));
	recent.load();
	recent.watchTree(recent.home, 0);
	try std.testing.expectEqual(@as(u32, 7), recent.dirs.count());

	var created = try std.Io.Dir.cwd().createFile(io, file, .{});
	created.close(io);
	var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
	const read = linux.read(recent.fd, &buffer, buffer.len);
	try std.testing.expect(linux.errno(read) == .SUCCESS);
	recent.handle(buffer[0..read]);

	var arena = std.heap.ArenaAllocator.init(allocator);
	defer arena.deinit();
	var out: std.ArrayList([]const u8) = .empty;
	try recent.search(arena.allocator(), "INVOICE", &out);
	try std.testing.expectEqual(@as(usize, 1), out.items.len);
	try std.testing.expectEqualStrings(file, out.items[0]);

	var reopened: Recent = .{ .allocator = allocator, .io = io, .home = try allocator.dupe(u8, root), .log = try allocator.dupe(u8, log) };
	defer reopened.deinit();
	reopened.load();
	out.clearRetainingCapacity();
	try reopened.search(arena.allocator(), "invoice", &out);
	try std.testing.expectEqual(@as(usize, 1), out.items.len);

	recent.prune(std.math.maxInt(i64));
	out.clearRetainingCapacity();
	try recent.search(arena.allocator(), "invoice", &out);
	try std.testing.expectEqual(@as(usize, 0), out.items.len);
	var emptied: Recent = .{ .allocator = allocator, .io = io, .home = try allocator.dupe(u8, root), .log = try allocator.dupe(u8, log) };
	defer emptied.deinit();
	emptied.load();
	try std.testing.expectEqual(@as(usize, 0), emptied.paths.items.len);
}
