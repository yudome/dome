const std = @import("std");
const proc = @import("../../primitives/proc.zig");
const exec = @import("../../primitives/exec.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn overlay(io: Io, allocator: Allocator, name: []const u8) ![]u8 {
	return overlayFrom(io, allocator, name, "");
}

pub fn overlayFrom(io: Io, allocator: Allocator, name: []const u8, tag: []const u8) ![]u8 {
	const repo = proc.repo(io, allocator);
	const script = try std.fs.path.join(allocator, &.{ repo, "vm", "images" });

	var argv: std.ArrayListUnmanaged([]const u8) = .empty;
	defer argv.deinit(allocator);
	try argv.appendSlice(allocator, &.{ "bash", script, "overlay", name });
	if (tag.len > 0) try argv.append(allocator, tag);

	const result = try exec.runLimit(io, allocator, argv.items, null, 1024 * 1024);
	defer result.deinit(allocator);

	if (result.code != 0) return error.ImageFailed;

	const trimmed = std.mem.trim(u8, result.out, " \t\r\n");
	const line = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| trimmed[at + 1 ..] else trimmed;

	if (line.len == 0) return error.ImageFailed;
	return allocator.dupe(u8, line);
}

pub const Boot = struct {
	kernel: []const u8,
	cmdline: []const u8,
};

pub fn boot(io: Io, allocator: Allocator, disk: []const u8) ?Boot {
	const result = exec.run(io, allocator, &.{ "qemu-img", "info", "-U", "--backing-chain", disk }) catch return null;
	defer result.deinit(allocator);
	if (result.code != 0) return null;
	return bootIn(io, allocator, result.out);
}

fn bootIn(io: Io, allocator: Allocator, info: []const u8) ?Boot {
	var lines = std.mem.splitScalar(u8, info, '\n');
	while (lines.next()) |line| {
		if (!std.mem.startsWith(u8, line, "image: ")) continue;
		const dir = std.fs.path.dirname(line["image: ".len..]) orelse continue;
		const kernel = std.fs.path.join(allocator, &.{ dir, "vmlinuz" }) catch return null;
		if (!proc.exists(io, kernel)) {
			allocator.free(kernel);
			continue;
		}
		const cmdline_path = std.fs.path.join(allocator, &.{ dir, "cmdline" }) catch return null;
		defer allocator.free(cmdline_path);
		const raw = proc.readFile(io, allocator, cmdline_path) catch return null;
		defer allocator.free(raw);
		const cmdline = allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n")) catch return null;
		return .{ .kernel = kernel, .cmdline = cmdline };
	}
	return null;
}

pub fn ensure(io: Io, allocator: Allocator) !void {
	const repo = proc.repo(io, allocator);
	const script = try std.fs.path.join(allocator, &.{ repo, "vm", "images" });

	const result = try exec.runLimit(io, allocator, &.{ "bash", script, "ensure" }, null, 1024 * 1024);
	defer result.deinit(allocator);

	if (result.code != 0) return error.ImageFailed;
}

test "the boot files come from the first image in the chain that has a kernel" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base", .{tmp.sub_path});
	defer allocator.free(base);
	const kernel = try std.fmt.allocPrint(allocator, "{s}/vmlinuz", .{base});
	defer allocator.free(kernel);
	const cmdline = try std.fmt.allocPrint(allocator, "{s}/cmdline", .{base});
	defer allocator.free(cmdline);
	try proc.writeFile(io, kernel, "k");
	try proc.writeFile(io, cmdline, "root=/dev/vda1 rw\n");

	const info = try std.fmt.allocPrint(allocator, "image: /nowhere/disk.qcow2\nbacking file: x\n\nimage: {s}/golden.qcow2\n", .{base});
	defer allocator.free(info);

	const found = bootIn(io, allocator, info).?;
	defer allocator.free(found.kernel);
	defer allocator.free(found.cmdline);
	try std.testing.expectEqualStrings(kernel, found.kernel);
	try std.testing.expectEqualStrings("root=/dev/vda1 rw", found.cmdline);
	try std.testing.expect(bootIn(io, allocator, "image: /nowhere/disk.qcow2\n") == null);
}
