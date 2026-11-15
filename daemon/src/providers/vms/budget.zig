const std = @import("std");
const proc = @import("../../primitives/proc.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Budget = struct {
	mem_mb: u32,
	cores: u32,
};

pub fn detect(io: Io, allocator: Allocator) Budget {
	const body = proc.readFile(io, allocator, "/proc/meminfo") catch "";
	defer allocator.free(body);

	const total_mb = fieldMb(body, "MemTotal:");
	const available_mb = fieldMb(body, "MemAvailable:");
	const cpus = std.Thread.getCpuCount() catch 1;

	// VMs reserve their full memory up front. Budget against what the host can
	// actually give today (three quarters of MemAvailable), not half of the
	// installed RAM: a 1 GB host reserve is kept for the daemon and the desktop.
	const floor = @min(total_mb, @max(total_mb / 2, 1024));
	const usable = if (available_mb > 0) available_mb * 3 / 4 else total_mb / 2;
	const cap = if (total_mb > 1024) total_mb - 1024 else total_mb;

	return .{
		.mem_mb = std.math.clamp(usable, floor, cap),
		.cores = @max(@as(u32, @intCast(cpus)), 1),
	};
}

fn fieldMb(body: []const u8, name: []const u8) u32 {
	const at = std.mem.indexOf(u8, body, name) orelse return 0;
	var index = at + name.len;
	while (index < body.len and (body[index] == ' ' or body[index] == '\t')) index += 1;
	var end = index;
	while (end < body.len and std.ascii.isDigit(body[end])) end += 1;
	const kb = std.fmt.parseInt(u64, body[index..end], 10) catch 0;
	return @intCast(kb / 1024);
}

test "the memory budget follows available memory" {
	const body = "MemTotal:       16328644 kB\nMemAvailable:   12700172 kB\n";
	const total = fieldMb(body, "MemTotal:");
	const available = fieldMb(body, "MemAvailable:");
	try std.testing.expectEqual(@as(u32, 15945), total);
	try std.testing.expectEqual(@as(u32, 12402), available);
	try std.testing.expect(available * 3 / 4 > total / 2);
}
