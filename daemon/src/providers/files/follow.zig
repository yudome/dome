const std = @import("std");
const linux = std.os.linux;
const sock = @import("../../primitives/sock.zig");
const guard = @import("../disk/guard.zig");

const Allocator = std.mem.Allocator;
const flush_ms = 500;
const flush_dirs = 512;

pub const Access = struct {
	uid: u32,
	groups: [64]u32 = undefined,
	count: usize = 0,

	pub fn of(pid: i32, uid: u32, gid: u32) Access {
		var access: Access = .{ .uid = uid };
		access.add(gid);
		var path_buf: [64]u8 = undefined;
		const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/status", .{pid}, 0) catch return access;
		const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
		if (linux.errno(fd) != .SUCCESS) return access;
		defer _ = linux.close(@intCast(fd));
		var buf: [4096]u8 = undefined;
		const read = linux.read(@intCast(fd), &buf, buf.len);
		if (linux.errno(read) != .SUCCESS) return access;
		const start = std.mem.indexOf(u8, buf[0..read], "\nGroups:") orelse return access;
		const end = std.mem.indexOfScalarPos(u8, buf[0..read], start + 1, '\n') orelse read;
		var groups = std.mem.tokenizeAny(u8, buf[start + 8 .. end], " \t");
		while (groups.next()) |group| access.add(std.fmt.parseInt(u32, group, 10) catch continue);
		return access;
	}

	fn add(self: *Access, gid: u32) void {
		if (self.count == self.groups.len) return;
		self.groups[self.count] = gid;
		self.count += 1;
	}

	pub fn canList(self: *const Access, path: []const u8) bool {
		if (self.uid == 0) return true;
		var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
		if (path.len == 0 or path[0] != '/' or path.len >= buf.len) return false;
		var at: usize = 0;
		while (at < path.len) {
			const end = std.mem.indexOfScalarPos(u8, path, at + 1, '/') orelse path.len;
			@memcpy(buf[0..end], path[0..end]);
			buf[end] = 0;
			if (!self.allowed(buf[0..@max(end, 1) :0], if (end == path.len) 5 else 1)) return false;
			at = end;
		}
		return true;
	}

	fn allowed(self: *const Access, path: [:0]const u8, need: u32) bool {
		var st: linux.Statx = undefined;
		if (linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true, .UID = true, .GID = true }, &st)) != .SUCCESS) return false;
		const owner = st.uid == self.uid;
		const group = std.mem.indexOfScalar(u32, self.groups[0..self.count], st.gid) != null;
		const bits = if (owner) (st.mode >> 6) & 7 else if (group) (st.mode >> 3) & 7 else st.mode & 7;
		return bits & need == need;
	}
};

pub fn serve(allocator: Allocator, client: i32, access: Access, roots: []const []const u8, mounts: []const []const u8) !void {
	const init_flags: linux.fanotify.InitFlags = .{ .CLOEXEC = true, .NONBLOCK = true, .CLASS = .NOTIF, .REPORT_DIR_FID = true, .REPORT_NAME = true };
	var fan: i32 = @intCast(linux.fanotify_init(init_flags, @bitCast(std.posix.O{ .ACCMODE = .RDONLY })));
	if (fan < 0) return error.FanotifyUnavailable;
	defer _ = linux.close(fan);

	var mount_fds: [16]i32 = undefined;
	var marked: usize = 0;
	defer for (mount_fds[0..marked]) |fd| {
		_ = linux.close(fd);
	};
	const mask: linux.fanotify.MarkMask = .{ .CREATE = true, .DELETE = true, .MOVED_FROM = true, .MOVED_TO = true, .ONDIR = true };
	for (mounts) |mount| {
		if (marked == mount_fds.len) break;
		var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
		const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{mount}, 0) catch continue;
		if (linux.errno(linux.fanotify_mark(fan, .{ .ADD = true, .FILESYSTEM = true }, mask, linux.AT.FDCWD, z)) != .SUCCESS) continue;
		const fd = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
		if (linux.errno(fd) != .SUCCESS) continue;
		mount_fds[marked] = @intCast(fd);
		marked += 1;
	}
	var partial = false;
	if (marked == 0) {
		_ = linux.close(fan);
		fan = @intCast(linux.fanotify_init(.{ .CLOEXEC = true, .NONBLOCK = true, .CLASS = .NOTIF }, @bitCast(std.posix.O{ .ACCMODE = .RDONLY })));
		if (fan < 0) return error.FanotifyUnavailable;
		const fallback: linux.fanotify.MarkMask = .{ .CLOSE_WRITE = true };
		for (mounts) |mount| {
			if (marked == mount_fds.len) break;
			var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
			const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{mount}, 0) catch continue;
			if (linux.errno(linux.fanotify_mark(fan, .{ .ADD = true, .FILESYSTEM = true }, fallback, linux.AT.FDCWD, z)) != .SUCCESS) continue;
			const fd = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
			if (linux.errno(fd) != .SUCCESS) continue;
			mount_fds[marked] = @intCast(fd);
			marked += 1;
		}
		if (marked == 0) return error.MarkFailed;
		partial = true;
	}
	try sock.writeAll(client, if (partial) "P\n" else "R\n");

	var pending: std.StringArrayHashMapUnmanaged(void) = .empty;
	defer {
		for (pending.keys()) |key| allocator.free(key);
		pending.deinit(allocator);
	}
	var overflow = false;
	var since: i64 = 0;
	var buffer: [64 * 1024]u8 align(8) = undefined;
	while (true) {
		var fds = [_]linux.pollfd{
			.{ .fd = client, .events = linux.POLL.IN, .revents = 0 },
			.{ .fd = @intCast(fan), .events = linux.POLL.IN, .revents = 0 },
		};
		const waiting = pending.count() > 0 or overflow;
		_ = linux.poll(&fds, fds.len, if (waiting) @intCast(@max(0, since + flush_ms - nowMs())) else -1);
		if (fds[0].revents != 0) return;
		if (fds[1].revents & linux.POLL.IN != 0) {
			const read = linux.read(fan, &buffer, buffer.len);
			if (linux.errno(read) == .SUCCESS) {
				const bytes = buffer[0..read];
				overflow = (if (partial) try collectFd(allocator, bytes, access, roots, &pending) else try collect(allocator, bytes, mount_fds[0..marked], access, roots, &pending)) or overflow;
			}
		}
		if (!waiting and (pending.count() > 0 or overflow)) since = nowMs();
		if (pending.count() == 0 and !overflow) continue;
		if (nowMs() - since < flush_ms and pending.count() < flush_dirs) continue;
		try send(client, &pending, overflow, allocator);
		overflow = false;
	}
}

fn collect(allocator: Allocator, bytes: []const u8, mount_fds: []const i32, access: Access, roots: []const []const u8, pending: *std.StringArrayHashMapUnmanaged(void)) !bool {
	var overflow = false;
	var offset: usize = 0;
	while (offset + @sizeOf(linux.fanotify.event_metadata) <= bytes.len) {
		const meta: *align(1) const linux.fanotify.event_metadata = @ptrCast(&bytes[offset]);
		if (meta.event_len < @sizeOf(linux.fanotify.event_metadata)) break;
		const record = bytes[offset..@min(bytes.len, offset + meta.event_len)];
		offset += meta.event_len;
		if (meta.mask.Q_OVERFLOW) {
			overflow = true;
			continue;
		}
		var at: usize = meta.metadata_len;
		while (at + @sizeOf(linux.fanotify.event_info_header) <= record.len) {
			const info: *align(1) const linux.fanotify.event_info_header = @ptrCast(&record[at]);
			if (info.len == 0) break;
			defer at += info.len;
			if (info.info_type != .DFID_NAME and info.info_type != .DFID) continue;
			const handle = at + @sizeOf(linux.fanotify.event_info_header) + @sizeOf(linux.kernel_fsid_t);
			var path_buf: [std.fs.max_path_bytes]u8 = undefined;
			const path = resolve(mount_fds, &record[handle], &path_buf) orelse continue;
			if (pending.contains(path) or !inside(path, roots) or !access.canList(path)) continue;
			try pending.put(allocator, try allocator.dupe(u8, path), {});
		}
	}
	return overflow;
}

fn collectFd(allocator: Allocator, bytes: []const u8, access: Access, roots: []const []const u8, pending: *std.StringArrayHashMapUnmanaged(void)) !bool {
	var overflow = false;
	var offset: usize = 0;
	while (offset + @sizeOf(linux.fanotify.event_metadata) <= bytes.len) {
		const meta: *align(1) const linux.fanotify.event_metadata = @ptrCast(&bytes[offset]);
		if (meta.event_len < @sizeOf(linux.fanotify.event_metadata)) break;
		offset += meta.event_len;
		if (meta.mask.Q_OVERFLOW) {
			overflow = true;
			continue;
		}
		if (meta.fd < 0) continue;
		defer _ = linux.close(meta.fd);
		var link: [32]u8 = undefined;
		const proc_path = std.fmt.bufPrintSentinel(&link, "/proc/self/fd/{d}", .{meta.fd}, 0) catch continue;
		var path_buf: [std.fs.max_path_bytes]u8 = undefined;
		const len = linux.readlink(proc_path, &path_buf, path_buf.len);
		if (linux.errno(len) != .SUCCESS) continue;
		const raw = path_buf[0..len];
		const full = if (std.mem.endsWith(u8, raw, " (deleted)")) raw[0 .. raw.len - " (deleted)".len] else raw;
		const path = if (meta.mask.ONDIR) full else std.fs.path.dirname(full) orelse continue;
		if (pending.contains(path) or !inside(path, roots) or !access.canList(path)) continue;
		try pending.put(allocator, try allocator.dupe(u8, path), {});
	}
	return overflow;
}

fn resolve(mount_fds: []const i32, handle: *const u8, buf: []u8) ?[]const u8 {
	for (mount_fds) |mount| {
		const fd = linux.syscall3(.open_by_handle_at, @as(usize, @bitCast(@as(isize, mount))), @intFromPtr(handle), @as(u32, @bitCast(linux.O{ .PATH = true, .CLOEXEC = true })));
		if (linux.errno(fd) != .SUCCESS) continue;
		defer _ = linux.close(@intCast(fd));
		var link: [32]u8 = undefined;
		const proc_path = std.fmt.bufPrintSentinel(&link, "/proc/self/fd/{d}", .{fd}, 0) catch return null;
		const len = linux.readlink(proc_path, buf.ptr, buf.len);
		if (linux.errno(len) != .SUCCESS) return null;
		const path = buf[0..len];
		return if (std.mem.endsWith(u8, path, " (deleted)")) null else path;
	}
	return null;
}

fn nowMs() i64 {
	var ts: linux.timespec = undefined;
	_ = linux.clock_gettime(.MONOTONIC, &ts);
	return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

fn inside(path: []const u8, roots: []const []const u8) bool {
	for (roots) |root| if (std.mem.eql(u8, root, "/") or guard.hasPrefix(path, root)) return true;
	return false;
}

fn send(client: i32, pending: *std.StringArrayHashMapUnmanaged(void), overflow: bool, allocator: Allocator) !void {
	if (overflow) try sock.writeAll(client, "O\n");
	for (pending.keys()) |path| {
		try sock.writeAll(client, "D ");
		try sock.writeAll(client, path);
		try sock.writeAll(client, "\n");
		allocator.free(path);
	}
	pending.clearRetainingCapacity();
	try sock.writeAll(client, ".\n");
}

pub fn listen(roots: []const []const u8, ctx: anytype) !void {
	var buffer: [64 * 1024]u8 = undefined;
	var connection = try sock.Connection.connect(guard.fsdSocket(), &buffer);
	defer connection.close();
	var request: [8192]u8 = undefined;
	var writer: std.Io.Writer = .fixed(&request);
	try writer.print("{{\"action\":\"follow\",\"paths\":{f}}}", .{std.json.fmt(roots, .{})});
	try connection.writeLine(writer.buffered());
	while (try connection.readLine()) |line| {
		if (std.mem.startsWith(u8, line, "D ")) {
			ctx.dir(line[2..]);
		} else if (std.mem.eql(u8, line, ".")) {
			ctx.flush();
		} else if (std.mem.eql(u8, line, "O")) {
			ctx.overflow();
		} else if (std.mem.eql(u8, line, "R")) {
			ctx.ready();
		} else if (std.mem.eql(u8, line, "P")) {
			ctx.partial();
		} else return error.Refused;
	}
}

test "the no-fid fallback reports the folder of a closed write" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);
	const file = try std.fmt.allocPrint(allocator, "{s}/fresh.txt", .{root});
	defer allocator.free(file);
	var created = try std.Io.Dir.cwd().createFile(io, file, .{});
	created.close(io);

	var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
	const z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{file}, 0);
	const fd = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
	try std.testing.expect(linux.errno(fd) == .SUCCESS);

	var meta: linux.fanotify.event_metadata = .{
		.event_len = @intCast(@sizeOf(linux.fanotify.event_metadata)),
		.vers = linux.fanotify.event_metadata.VERSION,
		.reserved = 0,
		.metadata_len = @intCast(@sizeOf(linux.fanotify.event_metadata)),
		.mask = .{ .CLOSE_WRITE = true },
		.fd = @intCast(fd),
		.pid = 0,
	};
	var pending: std.StringArrayHashMapUnmanaged(void) = .empty;
	defer {
		for (pending.keys()) |key| allocator.free(key);
		pending.deinit(allocator);
	}
	try std.testing.expect(!try collectFd(allocator, std.mem.asBytes(&meta), .{ .uid = @intCast(linux.geteuid()) }, &.{root}, &pending));
	try std.testing.expectEqual(@as(usize, 1), pending.count());
	try std.testing.expectEqualStrings(root, pending.keys()[0]);
}

test "access follows the permission bits of every folder on the path" {
	const access: Access = .{ .uid = 65534, .groups = @splat(65534), .count = 1 };
	try std.testing.expect(access.canList("/"));
	try std.testing.expect(!access.canList("/root"));
	const root: Access = .{ .uid = 0 };
	try std.testing.expect(root.canList("/root"));
}

test "serve reports the folder a new file appears in" {
	if (linux.geteuid() != 0) return error.SkipZigTest;
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);

	var pair: [2]i32 = undefined;
	if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS) return error.SocketFailed;
	defer _ = linux.close(pair[0]);
	var mounts = try guard.Guard.init(allocator, io, &.{});
	defer mounts.deinit(allocator);
	const roots = [_][]const u8{root};
	const mount_list = [_][]const u8{mounts.mountRoot(root)};
	const thread = try std.Thread.spawn(.{}, struct {
		fn run(fd: i32, r: []const []const u8, m: []const []const u8) void {
			serve(std.testing.allocator, fd, .{ .uid = 0 }, r, m) catch {};
			_ = linux.close(fd);
		}
	}.run, .{ pair[1], &roots, &mount_list });
	defer thread.join();

	defer _ = linux.shutdown(pair[0], linux.SHUT.RDWR);
	const expected = try std.fmt.allocPrint(allocator, "D {s}\n", .{root});
	defer allocator.free(expected);
	var buf: [8192]u8 = undefined;
	var len: usize = 0;
	var waited: usize = 0;
	while (std.mem.indexOf(u8, buf[0..len], expected) == null) : (waited += 1) {
		if (waited == 20) return error.NoEvent;
		const file = try std.fmt.allocPrint(allocator, "{s}/new-{d}.txt", .{ root, waited });
		defer allocator.free(file);
		var created = try std.Io.Dir.cwd().createFile(io, file, .{});
		created.close(io);
		var fds = [_]linux.pollfd{.{ .fd = pair[0], .events = linux.POLL.IN, .revents = 0 }};
		if (linux.poll(&fds, 1, 300) == 0) continue;
		const read = linux.read(pair[0], buf[len..].ptr, buf.len - len);
		if (linux.errno(read) != .SUCCESS or read == 0) return error.ReadFailed;
		len += read;
	}
	try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "R\n"));
}
