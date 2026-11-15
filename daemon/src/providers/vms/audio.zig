const std = @import("std");
const exec = @import("../../primitives/exec.zig");
const sleep = @import("../../primitives/sleep.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const sink = "yudae-vm";

pub fn available(io: Io, allocator: Allocator) bool {
	const result = exec.run(io, allocator, &.{ "pactl", "info" }) catch return false;
	defer result.deinit(allocator);
	return result.code == 0;
}

pub fn qemuPa(io: Io, allocator: Allocator, qemu: []const u8) bool {
	const result = exec.run(io, allocator, &.{ qemu, "-audiodev", "help" }) catch return false;
	defer result.deinit(allocator);
	return result.code == 0 and std.mem.indexOf(u8, result.out, "pa") != null;
}

pub fn ensureSink(io: Io, allocator: Allocator) bool {
	var attempt: usize = 0;
	while (attempt < 20) : (attempt += 1) {
		if (available(io, allocator)) break;
		sleep.ms(100);
	}


	const list = exec.run(io, allocator, &.{ "pactl", "list", "short", "sinks" }) catch return false;
	defer list.deinit(allocator);
	if (std.mem.indexOf(u8, list.out, sink) != null) return true;


	const result = exec.run(io, allocator, &.{
		"pactl", "load-module", "module-null-sink",
		"sink_name=" ++ sink,
		"sink_properties=device.description=" ++ sink,
	}) catch return false;
	defer result.deinit(allocator);
	return result.code == 0;
}

pub fn passthrough(io: Io, allocator: Allocator, on: bool) bool {
	if (!on) {
		unload(io, allocator);
		return true;
	}
	if (!ensureSink(io, allocator)) return false;
	if (loopback(io, allocator) != null) return true;

	const result = exec.run(io, allocator, &.{ "pactl", "get-default-sink" }) catch return false;
	defer result.deinit(allocator);
	const output = std.mem.trim(u8, result.out, " \r\n");

	if (result.code != 0 or output.len == 0 or std.mem.eql(u8, output, sink)) return false;

	const source = std.fmt.allocPrint(allocator, "source={s}.monitor", .{sink}) catch return false;
	const target = std.fmt.allocPrint(allocator, "sink={s}", .{output}) catch return false;
	const load = exec.run(io, allocator, &.{ "pactl", "load-module", "module-loopback", source, target, "latency_msec=20" }) catch return false;
	defer load.deinit(allocator);

	return load.code == 0;
}

fn loopback(io: Io, allocator: Allocator) ?[]u8 {
	const result = exec.run(io, allocator, &.{ "pactl", "list", "short", "modules" }) catch return null;
	defer result.deinit(allocator);

	var lines = std.mem.splitScalar(u8, result.out, '\n');
	while (lines.next()) |line| {
		if (std.mem.indexOf(u8, line, "module-loopback") == null) continue;
		if (std.mem.indexOf(u8, line, "yudae-vm.monitor") == null) continue;
		var fields = std.mem.tokenizeAny(u8, line, " \t");
		const id = fields.next() orelse continue;
		return allocator.dupe(u8, id) catch null;
	}
	return null;
}

fn unload(io: Io, allocator: Allocator) void {
	while (loopback(io, allocator)) |id| {
		const result = exec.run(io, allocator, &.{ "pactl", "unload-module", id }) catch break;
		defer result.deinit(allocator);
		allocator.free(id);
		if (result.code != 0) break;
	}
}

test "the loopback is found by its source" {
	const line = "536870917\tmodule-loopback\tsource=yudae-vm.monitor sink=alsa_output.pci-0000_00_1f.3.analog-stereo latency_msec=20\n";
	var fields = std.mem.tokenizeAny(u8, line, " \t");
	try std.testing.expectEqualStrings("536870917", fields.next().?);
	try std.testing.expect(std.mem.indexOf(u8, line, "yudae-vm.monitor") != null);
}
