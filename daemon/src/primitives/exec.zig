const std = @import("std");

pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;

pub var spawned: std.atomic.Value(u64) = .init(0);

pub fn spawn(io: Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
	_ = spawned.fetchAdd(1, .monotonic);
	return start(io, options);
}

fn start(io: Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
	const search = if (options.environ_map) |map| map.get("PATH") else null;
	if (options.argv.len == 0 or !runnable(options.argv[0], search orelse std.mem.span(std.c.getenv("PATH") orelse "/usr/bin"))) return error.FileNotFound;

	return std.process.spawn(io, options);
}

pub fn runnable(name: []const u8, search: []const u8) bool {
	var buffer: [std.fs.max_path_bytes]u8 = undefined;

	if (std.mem.indexOfScalar(u8, name, '/') != null) return executable(&buffer, name);

	var dirs = std.mem.tokenizeScalar(u8, search, ':');
	while (dirs.next()) |dir| {
		const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name }) catch continue;
		if (executable(&buffer, full)) return true;
	}

	return false;
}

fn executable(buffer: *[std.fs.max_path_bytes]u8, path: []const u8) bool {
	if (path.len >= buffer.len) return false;
	if (path.ptr != buffer.ptr) @memcpy(buffer[0..path.len], path);
	buffer[path.len] = 0;
	return std.c.access(@ptrCast(buffer), std.c.X_OK) == 0;
}

test "runnable finds binaries on the search path and rejects missing ones" {
	try std.testing.expect(runnable("sh", "/nonexistent:/usr/bin:/bin"));
	try std.testing.expect(runnable("/bin/sh", ""));
	try std.testing.expect(!runnable("yudae-no-such-binary", "/usr/bin:/bin"));
	try std.testing.expect(!runnable("/nonexistent/sh", "/usr/bin"));
}

pub const Result = struct {
	code: u8,
	out: []u8,
	err: []u8,

	pub fn deinit(self: Result, allocator: Allocator) void {
		allocator.free(self.out);
		allocator.free(self.err);
	}
};

pub fn run(io: Io, allocator: Allocator, argv: []const []const u8) !Result {
	return runEnv(io, allocator, argv, null);
}

pub fn runEnv(io: Io, allocator: Allocator, argv: []const []const u8, environ_map: ?*const std.process.Environ.Map) !Result {
	return runLimit(io, allocator, argv, environ_map, 4 * 1024 * 1024);
}

pub fn runDir(io: Io, allocator: Allocator, argv: []const []const u8, cwd: []const u8, environ_map: ?*const std.process.Environ.Map) !Result {
	return runFull(io, allocator, argv, environ_map, 4 * 1024 * 1024, cwd);
}

pub fn runLimit(io: Io, allocator: Allocator, argv: []const []const u8, environ_map: ?*const std.process.Environ.Map, limit: usize) !Result {
	return runFull(io, allocator, argv, environ_map, limit, null);
}

fn runFull(io: Io, allocator: Allocator, argv: []const []const u8, environ_map: ?*const std.process.Environ.Map, limit: usize, cwd: ?[]const u8) !Result {
	var child = try start(io, .{
		.argv = argv,
		.cwd = if (cwd) |path| .{ .path = path } else .inherit,
		.stdin = .ignore,
		.stdout = .pipe,
		.stderr = .pipe,
		.environ_map = environ_map,
	});

	var multi_buffer: Io.File.MultiReader.Buffer(2) = undefined;
	var multi: Io.File.MultiReader = undefined;
	multi.init(allocator, io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
	defer multi.deinit();

	while (multi.fill(64, .none)) |_| {
		if (multi.reader(0).buffered().len > limit) {
			if (child.id) |pid| _ = std.posix.kill(pid, std.posix.SIG.KILL) catch {};
			break;
		}
		if (multi.reader(1).buffered().len > 64 * 1024) break;
	} else |err| switch (err) {
		error.EndOfStream => {},
		else => |e| return e,
	}

	try multi.checkAnyError();

	const term = child.wait(io) catch {
		return .{ .code = 1, .out = try multi.toOwnedSlice(0), .err = try multi.toOwnedSlice(1) };
	};

	const code: u8 = switch (term) {
		.exited => |status| status,
		else => 1,
	};

	return .{ .code = code, .out = try multi.toOwnedSlice(0), .err = try multi.toOwnedSlice(1) };
}

