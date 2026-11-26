const std = @import("std");
const json = @import("primitives/json.zig");
const proc = @import("primitives/proc.zig");
const sock = @import("primitives/sock.zig");
const benchmod = @import("bench.zig");
const bench_widgets = @import("bench_widgets.zig");
const bench_disk = @import("bench_disk.zig");
const bench_files = @import("bench_files.zig");
const bench_wallpaper = @import("bench_wallpaper.zig");
const paritymod = @import("parity.zig");
const mcpmod = @import("mcp.zig");
const sleep = @import("primitives/sleep.zig");
const environ = @import("primitives/environ.zig");
const exec = @import("primitives/exec.zig");
const hypr = @import("primitives/hypr.zig");
const human = @import("human.zig");
const wayland = @import("primitives/wayland.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub var json_out = false;

pub fn state(io: Io, args: []const []const u8) !void {
	const body = try fetch(io);
	defer std.heap.smp_allocator.free(body);
	showDepth(io, body, 1);
	_ = args;
}

pub fn fetch(io: Io) ![]u8 {
	const path = try proc.socketPath(io, std.heap.smp_allocator);
	defer std.heap.smp_allocator.free(path);

	var read_buffer: [1048576]u8 = undefined;
	var connection = sock.Connection.connect(path, &read_buffer) catch {
		std.debug.print("yudaemond is not running\n", .{});
		std.process.exit(2);
	};
	defer connection.close();

	try connection.writeLine(sock.sync);

	const message = try connection.readLine() orelse {
		std.debug.print("yudaemond sent no state\n", .{});
		std.process.exit(2);
	};

	return std.heap.smp_allocator.dupe(u8, message);
}

pub fn transition(io: Io, args: []const []const u8) !void {
	if (args.len < 4 or !std.mem.eql(u8, args[2], "check")) {
		std.debug.print("usage: yudae transition check <transition.frag>\n", .{});
		std.process.exit(2);
	}

	const source = proc.readFileLimit(io, std.heap.smp_allocator, args[3], 256 * 1024) catch |err| {
		std.debug.print("{s}: {s}\n", .{ args[3], @errorName(err) });
		std.process.exit(1);
	};
	const shader = try std.heap.smp_allocator.dupeSentinel(u8, source, 0);

	var err: [4096]u8 = undefined;
	if (!wayland.checkShader(shader, &err)) {
		std.debug.print("{s}: {s}\n", .{ args[3], std.mem.sliceTo(&err, 0) });
		std.process.exit(1);
	}

	std.debug.print("ok {s}\n", .{args[3]});
}

pub fn files(io: Io, args: []const []const u8) !void {
	if (args.len < 3 or !std.mem.eql(u8, args[2], "rebuild")) {
		std.debug.print("usage: yudae files rebuild\n", .{});
		std.process.exit(2);
	}
	const path = try proc.socketPath(io, std.heap.smp_allocator);
	defer std.heap.smp_allocator.free(path);
	var read_buffer: [4096]u8 = undefined;
	var connection = sock.Connection.connect(path, &read_buffer) catch {
		std.debug.print("yudaemond is not running\n", .{});
		std.process.exit(2);
	};
	defer connection.close();
	try connection.writeLine("{\"cmd\":{\"launcher\":{\"rebuildFiles\":true}}}");
}

pub fn logout(io: Io) !void {
	try send(io, "{\"cmd\":{\"system\":{\"logout\":true}}}");
}

pub fn lock(io: Io) !void {
	try send(io, "{\"cmd\":{\"lockscreen\":{\"lock\":true}}}");
}

fn send(io: Io, line: []const u8) !void {
	const path = try proc.socketPath(io, std.heap.smp_allocator);
	defer std.heap.smp_allocator.free(path);

	var read_buffer: [4096]u8 = undefined;
	var connection = sock.Connection.connect(path, &read_buffer) catch {
		std.debug.print("yudaemond is not running\n", .{});
		std.process.exit(2);
	};
	defer connection.close();

	try connection.writeLine(line);
}

pub fn doctor(io: Io) !void {
	const body = try fetch(io);
	defer std.heap.smp_allocator.free(body);

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const parsed = json.parse(allocator, body) catch {
		std.debug.print("state unreadable\n", .{});
		std.process.exit(2);
	};
	const value = parsed.value;

	var out: std.Io.Writer.Allocating = .init(allocator);
	const w = &out.writer;
	try w.writeAll("{");
	if (json.field(value, "opencode")) |provider| {
		try w.print("\"opencode\":{{\"up\":{},\"state\":", .{json.flag(provider, "connected")});
		try std.json.Stringify.encodeJsonString(json.textAt(provider, "state"), .{}, w);
		try w.writeAll(",\"error\":");
		try std.json.Stringify.encodeJsonString(json.textAt(provider, "usageError"), .{}, w);
		try w.writeAll("}");
	} else try w.writeAll("\"opencode\":null");
	if (json.field(value, "codex")) |provider| try w.print(",\"codex\":{}", .{json.flag(provider, "signedIn")});
	if (json.field(value, "weather")) |provider| try w.print(",\"weather\":{}", .{json.integer(json.field(provider, "fetched")) > 0});
	if (json.field(value, "github")) |provider| try w.print(",\"github\":{}", .{json.textAt(provider, "login").len > 0});
	if (json.field(value, "cursor")) |provider| try w.print(",\"cursor\":{}", .{json.flag(provider, "valid")});
	try w.writeAll("}");

	if (json_out) return printResult(io, out.written());

	var text: std.Io.Writer.Allocating = .init(allocator);
	const t = &text.writer;
	if (json.field(value, "opencode")) |provider| {
		const usage = json.textAt(provider, "usageError");
		try t.print("opencode  {s}  {s}{s}{s}\n", .{ if (json.flag(provider, "connected")) "up  " else "down", json.textAt(provider, "state"), if (usage.len > 0) "  " else "", usage });
	} else try t.writeAll("opencode  missing\n");
	if (json.field(value, "codex")) |provider| try t.print("codex     {s}\n", .{if (json.flag(provider, "signedIn")) "up" else "down"});
	if (json.field(value, "weather")) |provider| try t.print("weather   {s}\n", .{if (json.integer(json.field(provider, "fetched")) > 0) "up" else "down"});
	if (json.field(value, "github")) |provider| try t.print("github    {s}\n", .{if (json.textAt(provider, "login").len > 0) "up" else "down"});
	if (json.field(value, "cursor")) |provider| try t.print("cursor    {s}\n", .{if (json.flag(provider, "valid")) "up" else "down"});
	printResult(io, std.mem.trimEnd(u8, text.written(), "\n"));
}

pub fn restart(io: Io) !void {
	const allocator = std.heap.smp_allocator;
	const user = exec.run(io, allocator, &.{ "systemctl", "--user", "restart", "yudaemond" }) catch {
		std.debug.print("yudae: systemctl is not available\n", .{});
		std.process.exit(1);
	};
	defer user.deinit(allocator);
	if (user.code != 0) {
		const system = exec.run(io, allocator, &.{ "systemctl", "restart", "yudaemond" }) catch std.process.exit(1);
		defer system.deinit(allocator);
		if (system.code != 0) {
			std.debug.print("yudae: restart failed: {s}", .{if (std.mem.indexOf(u8, user.err, "not found") != null) system.err else user.err});
			std.process.exit(1);
		}
	}

	var tries: usize = 0;
	while (tries < 100) : (tries += 1) {
		if (probe(io)) |pid| {
			var buffer: [256]u8 = undefined;
			const body = std.fmt.bufPrint(&buffer, "{{\"restarted\":true,\"pid\":{d}}}", .{pid}) catch return;
			if (json_out) return printResult(io, body);
			const line = std.fmt.bufPrint(&buffer, "yudaemond restarted, pid {d}", .{pid}) catch return;
			return printResult(io, line);
		}
		sleep.ms(100);
	}

	std.debug.print("yudaemond did not come back within 10s\n", .{});
	std.process.exit(1);
}

fn probe(io: Io) ?i64 {
	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();
	const path = proc.socketPath(io, allocator) catch return null;
	var read_buffer: [1048576]u8 = undefined;
	var connection = sock.Connection.connect(path, &read_buffer) catch return null;
	defer connection.close();
	connection.writeLine(sock.sync) catch return null;
	const message = (connection.readLine() catch return null) orelse return null;
	const parsed = json.parse(allocator, message) catch return null;
	return json.integer(json.deep(parsed.value, &.{ "daemon", "pid" }));
}

pub fn bench(io: Io, args: []const []const u8) !void {
	if (args.len > 2 and std.mem.eql(u8, args[2], "widgets")) return bench_widgets.run(io, args);
	if (args.len > 2 and std.mem.eql(u8, args[2], "disk")) return bench_disk.run(io, args[2..]);
	if (args.len > 2 and std.mem.eql(u8, args[2], "files")) return bench_files.run(io, args[2..]);
	if (args.len > 2 and std.mem.eql(u8, args[2], "wallpaper")) return bench_wallpaper.run(io, args[2..]);

	return benchmod.run(io, args);
}

pub fn parity(io: Io, args: []const []const u8) !void {
	return paritymod.run(io, args);
}

pub fn mcp(io: Io, args: []const []const u8) !void {
	return mcpmod.run(io, args);
}

pub fn plugin(io: Io, args: []const []const u8) !void {
	if (args.len < 3) {
		std.debug.print("usage: yudae plugin <list|build|load|unload|theme|add|update|reload> [id|url]\n", .{});
		std.process.exit(2);
	}

	const method = args[2];
	const rest = args[3..];
	const needs_id = std.mem.eql(u8, method, "build") or std.mem.eql(u8, method, "load") or
		std.mem.eql(u8, method, "unload") or std.mem.eql(u8, method, "update") or std.mem.eql(u8, method, "theme");

	if (needs_id and rest.len == 0) {
		std.debug.print("usage: yudae plugin {s} <id>\n", .{method});
		std.process.exit(2);
	}

	if (std.mem.eql(u8, method, "add") and rest.len == 0) {
		std.debug.print("usage: yudae plugin add <git-url>\n", .{});
		std.process.exit(2);
	}

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var out: std.Io.Writer.Allocating = .init(allocator);
	const writer = &out.writer;

	try writer.writeAll("{\"call\":{\"target\":\"plugins\",\"method\":");
	try std.json.Stringify.encodeJsonString(method, .{}, writer);
	try writer.writeAll(",\"args\":{");

	if (needs_id) {
		try writer.writeAll("\"id\":");
		try std.json.Stringify.encodeJsonString(rest[0], .{}, writer);
	} else if (std.mem.eql(u8, method, "add")) {
		try writer.writeAll("\"url\":");
		try std.json.Stringify.encodeJsonString(rest[0], .{}, writer);
	}

	try writer.writeAll("}}}");

	const result = roundTrip(io, allocator, out.written(), false) catch std.process.exit(1);
	show(io, result);
}

pub fn call(io: Io, args: []const []const u8) !void {
	var quiet = false;
	var index: usize = 2;

	while (index < args.len and args[index].len > 0 and args[index][0] == '-') {
		if (std.mem.eql(u8, args[index], "-q")) quiet = true;
		index += 1;
	}

	if (index + 1 >= args.len) {
		std.debug.print("usage: yudae call [-q] <target> <method> [args...]\n", .{});
		std.process.exit(2);
	}

	const target = args[index];
	const method = args[index + 1];
	const rest = args[index + 2 ..];

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var out: std.Io.Writer.Allocating = .init(allocator);
	const writer = &out.writer;

	try writer.writeAll("{\"call\":{\"target\":");
	try std.json.Stringify.encodeJsonString(target, .{}, writer);
	try writer.writeAll(",\"method\":");
	try std.json.Stringify.encodeJsonString(method, .{}, writer);
	try writer.writeAll(",\"args\":");

	if (rest.len == 0) {
		try writer.writeAll("{}");
	} else if (rest.len == 1) {
		try writeArg(allocator, writer, rest[0]);
	} else {
		try writer.writeAll("[");

		for (rest, 0..) |arg, position| {
			if (position > 0) try writer.writeAll(",");
			try writeArg(allocator, writer, arg);
		}

		try writer.writeAll("]");
	}

	try writer.writeAll("}}");

	const result = roundTrip(io, allocator, out.written(), quiet) catch {
		if (quiet) return;
		std.process.exit(1);
	};

	if (!quiet and result.len > 0 and !std.mem.eql(u8, result, "{}")) show(io, result);
}

pub fn ui(io: Io, args: []const []const u8) !void {
	if (args.len < 3 or !std.mem.eql(u8, args[2], "tree")) {
		std.debug.print("usage: yudae ui tree\n", .{});
		std.process.exit(2);
	}

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();

	const result = roundTrip(io, arena.allocator(), "{\"call\":{\"target\":\"ui\",\"method\":\"tree\",\"args\":{}}}", false) catch std.process.exit(1);
	show(io, result);
}


fn envText(keys: []const [*:0]const u8) []const u8 {
	for (keys) |key| {
		if (std.c.getenv(key)) |value| {
			const text = std.mem.span(value);
			if (text.len > 0) return text;
		}
	}

	return "";
}

fn agentHarness() []const u8 {
	const direct = envText(&.{"AI_AGENT"});
	if (direct.len > 0) return direct;
	if (std.c.getenv("OPENCODE") != null) return "opencode";
	if (std.c.getenv("CLAUDECODE") != null) return "claude";
	if (std.c.getenv("CODEX_HOME") != null) return "codex";
	return "";
}

fn stampVm(io: Io, allocator: Allocator, name: []const u8) void {
	if (name.len == 0) return;

	const harness = agentHarness();
	const session = envText(&.{ "OPENCODE_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "CODEX_SESSION_ID" });
	if (harness.len == 0 and session.len == 0) return;

	var out: std.Io.Writer.Allocating = .init(allocator);

	out.writer.writeAll("{\"call\":{\"target\":\"vms\",\"method\":\"agent\",\"args\":{\"name\":") catch return;
	std.json.Stringify.encodeJsonString(name, .{}, &out.writer) catch return;
	out.writer.writeAll(",\"harness\":") catch return;
	std.json.Stringify.encodeJsonString(harness, .{}, &out.writer) catch return;
	out.writer.writeAll(",\"session\":") catch return;
	std.json.Stringify.encodeJsonString(session, .{}, &out.writer) catch return;
	out.writer.writeAll("}}}") catch return;

	_ = roundTrip(io, allocator, out.written(), true) catch {};
}

pub fn open(io: Io, args: []const []const u8) !void {
	if (args.len < 3) {
		std.debug.print("usage: yudae open <vm> [app]\n", .{});
		std.process.exit(2);
	}

	const name = args[2];

	if (args.len < 4) {
		var view_args = [_][]const u8{ "yudae", "vm", "view", name };
		return virtualMachines(io, &view_args);
	}

	const app_name = args[3];

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var out: std.Io.Writer.Allocating = .init(allocator);
	out.writer.writeAll("{\"call\":{\"target\":\"vms\",\"method\":\"gui\",\"args\":{\"name\":") catch return;
	std.json.Stringify.encodeJsonString(name, .{}, &out.writer) catch return;
	out.writer.writeAll(",\"app\":") catch return;
	std.json.Stringify.encodeJsonString(app_name, .{}, &out.writer) catch return;
	out.writer.writeAll("}}}") catch return;

	const result = roundTrip(io, allocator, out.written(), false) catch std.process.exit(1);
	show(io, result);
}

pub fn virtualMachines(io: Io, args: []const []const u8) !void {
	if (args.len < 3) {
		std.debug.print("usage: yudae vm <create|list|start|stop|exec|screenshot|key|type|click|move|drag|wait|sleep|wake|destroy|snapshot|restore|fork|state|view|scenario|doctor> [args...]\n", .{});
		std.process.exit(2);
	}

	if (std.mem.eql(u8, args[2], "doctor")) {
		const allocator = std.heap.smp_allocator;
		const repo = proc.repo(io, allocator);
		const result = (if (json_out) exec.runDir(io, allocator, &.{ "xmake", "doctor", "--json" }, repo, null) else exec.runDir(io, allocator, &.{ "xmake", "doctor" }, repo, null)) catch std.process.exit(1);
		defer result.deinit(allocator);
		printResult(io, std.mem.trimEnd(u8, result.out, "\n"));
		if (result.code != 0) std.process.exit(result.code);
		return;
	}

	const method = if (std.mem.eql(u8, args[2], "scenario")) "run_scenario" else args[2];
	const rest = args[3..];

	if (std.mem.eql(u8, method, "view")) {
		if (rest.len == 0) {
			std.debug.print("usage: yudae vm view <name>\n", .{});
			std.process.exit(2);
		}

		var view_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
		defer view_arena.deinit();
		const view_allocator = view_arena.allocator();

		stampVm(io, view_allocator, rest[0]);

		const message = try std.fmt.allocPrint(view_allocator, "{{\"call\":{{\"target\":\"vms\",\"method\":\"view\",\"args\":{{\"name\":\"{s}\"}}}}}}", .{rest[0]});
		const result = roundTrip(io, view_allocator, message, false) catch std.process.exit(1);

		const start = try std.fmt.allocPrint(view_allocator, "{{\"call\":{{\"target\":\"vms\",\"method\":\"start\",\"args\":{{\"name\":\"{s}\"}}}}}}", .{rest[0]});
		_ = roundTrip(io, view_allocator, start, true) catch {};

		app(io, &.{ "yudae", "app", "open", "vms", "--vm", rest[0] }) catch {};

		show(io, result);
		return;
	}

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var out: std.Io.Writer.Allocating = .init(allocator);
	const writer = &out.writer;

	try writer.writeAll("{\"call\":{\"target\":\"vms\",\"method\":");
	try std.json.Stringify.encodeJsonString(method, .{}, writer);
	try writer.writeAll(",\"args\":{");

	var wrote = false;
	var index: usize = 0;
	var name: []const u8 = "";
	var positional: std.ArrayList([]const u8) = .empty;

	while (index < rest.len) : (index += 1) {
		const arg = rest[index];

		if (std.mem.eql(u8, arg, "--cores") and index + 1 < rest.len) {
			index += 1;
			try writeRawField(writer, &wrote, "cores", rest[index]);
		} else if (std.mem.eql(u8, arg, "--mem") and index + 1 < rest.len) {
			index += 1;
			try writeRawField(writer, &wrote, "mem", rest[index]);
		} else if (std.mem.eql(u8, arg, "--from") and index + 1 < rest.len) {
			index += 1;
			try writeField(allocator, writer, &wrote, "from", rest[index]);
		} else if (std.mem.eql(u8, arg, "--agent") and index + 1 < rest.len) {
			index += 1;
			try writeField(allocator, writer, &wrote, "agent", rest[index]);
		} else if (std.mem.eql(u8, arg, "--tag") and index + 1 < rest.len) {
			index += 1;
			try writeField(allocator, writer, &wrote, "tag", rest[index]);
		} else if (std.mem.eql(u8, arg, "--until") and index + 1 < rest.len) {
			index += 1;
			try writeField(allocator, writer, &wrote, "until", rest[index]);
		} else if (std.mem.eql(u8, arg, "--timeout") and index + 1 < rest.len) {
			index += 1;
			try writeField(allocator, writer, &wrote, "timeout", rest[index]);
		} else if (std.mem.eql(u8, arg, "--gl")) {
			try writeRawField(writer, &wrote, "gl", "true");
		} else if (std.mem.eql(u8, arg, "--human")) {
			try writeRawField(writer, &wrote, "human", "true");
		} else if (std.mem.eql(u8, arg, "--hold") and index + 1 < rest.len) {
			index += 1;
			try writeRawField(writer, &wrote, "hold", rest[index]);
		} else if (name.len == 0) {
			name = arg;
		} else {
			try positional.append(allocator, arg);
		}
	}

	if (name.len > 0) try writeField(allocator, writer, &wrote, "name", name);

	if (name.len > 0 and !std.mem.eql(u8, method, "run_scenario")) stampVm(io, allocator, name);

	if (std.mem.eql(u8, method, "exec")) {
		try writeField(allocator, writer, &wrote, "cmd", try std.mem.join(allocator, " ", positional.items));
	} else if (std.mem.eql(u8, method, "type")) {
		try writeField(allocator, writer, &wrote, "text", try std.mem.join(allocator, " ", positional.items));
	} else if (std.mem.eql(u8, method, "key")) {
		try writeArrayField(allocator, writer, &wrote, "keys", positional.items);
	} else if (std.mem.eql(u8, method, "ui")) {
		if (positional.items.len >= 1) try writeField(allocator, writer, &wrote, "action", positional.items[0]);
	} else if (std.mem.eql(u8, method, "click") or std.mem.eql(u8, method, "move") or std.mem.eql(u8, method, "drag")) {
		if (positional.items.len >= 1) try writeRawField(writer, &wrote, "x", positional.items[0]);
		if (positional.items.len >= 2) try writeRawField(writer, &wrote, "y", positional.items[1]);
		if (positional.items.len >= 3) try writeRawField(writer, &wrote, "toX", positional.items[2]);
		if (positional.items.len >= 4) try writeRawField(writer, &wrote, "toY", positional.items[3]);
		if (positional.items.len >= 5) try writeRawField(writer, &wrote, "steps", positional.items[4]);
	} else if (std.mem.eql(u8, method, "gui")) {
		if (positional.items.len >= 1) try writeField(allocator, writer, &wrote, "app", positional.items[0]);
	} else if (std.mem.eql(u8, method, "scroll")) {
		if (positional.items.len >= 1) try writeRawField(writer, &wrote, "dy", positional.items[0]);
		if (positional.items.len >= 2) try writeRawField(writer, &wrote, "x", positional.items[1]);
		if (positional.items.len >= 3) try writeRawField(writer, &wrote, "y", positional.items[2]);
	} else if (std.mem.eql(u8, method, "run_scenario")) {
		if (positional.items.len >= 1) {
			try writeField(allocator, writer, &wrote, "scenario", positional.items[0]);
		} else if (name.len > 0) {
			try writeField(allocator, writer, &wrote, "scenario", name);
		}
	} else if (std.mem.eql(u8, method, "screenshot")) {
		if (positional.items.len >= 1) try writeField(allocator, writer, &wrote, "path", positional.items[0]);
	} else if (std.mem.eql(u8, method, "snapshot") or std.mem.eql(u8, method, "restore")) {
		if (positional.items.len >= 1) try writeField(allocator, writer, &wrote, "tag", positional.items[0]);
	} else if (std.mem.eql(u8, method, "fork")) {
		if (positional.items.len >= 1) try writeField(allocator, writer, &wrote, "from", positional.items[0]);
	}

	try writer.writeAll("}}}");

	const result = roundTrip(io, allocator, out.written(), false) catch std.process.exit(1);

	if (std.mem.eql(u8, method, "exec") and !json_out) return execOutput(io, result);
	show(io, result);

	if (std.mem.eql(u8, method, "run_scenario") and std.mem.indexOf(u8, result, "\"ok\":false") != null) std.process.exit(1);
}

fn execOutput(io: Io, body: []const u8) void {
	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const parsed = json.parse(arena.allocator(), body) catch return printResult(io, body);
	const out = json.textAt(parsed.value, "out");
	const err = json.textAt(parsed.value, "err");
	const code = json.integer(json.field(parsed.value, "code"));

	var buffer: [8192]u8 = undefined;
	var writer = std.Io.File.stdout().writer(io, &buffer);
	writer.interface.writeAll(out) catch {};
	writer.interface.flush() catch {};
	if (err.len > 0) std.debug.print("{s}", .{err});
	if (code != 0) std.process.exit(@intCast(std.math.clamp(code, 1, 255)));
}

fn writeField(allocator: Allocator, writer: *std.Io.Writer, wrote: *bool, key: []const u8, value: []const u8) !void {
	if (value.len == 0) return;
	if (wrote.*) try writer.writeAll(",");
	wrote.* = true;
	try std.json.Stringify.encodeJsonString(key, .{}, writer);
	try writer.writeAll(":");
	try std.json.Stringify.encodeJsonString(value, .{}, writer);
	_ = allocator;
}

fn writeRawField(writer: *std.Io.Writer, wrote: *bool, key: []const u8, value: []const u8) !void {
	if (wrote.*) try writer.writeAll(",");
	wrote.* = true;
	try std.json.Stringify.encodeJsonString(key, .{}, writer);
	try writer.writeAll(":");
	try writer.writeAll(value);
}

fn writeArrayField(allocator: Allocator, writer: *std.Io.Writer, wrote: *bool, key: []const u8, values: []const []const u8) !void {
	if (wrote.*) try writer.writeAll(",");
	wrote.* = true;
	try std.json.Stringify.encodeJsonString(key, .{}, writer);
	try writer.writeAll(":[");

	for (values, 0..) |value, index| {
		if (index > 0) try writer.writeAll(",");
		try std.json.Stringify.encodeJsonString(value, .{}, writer);
	}

	try writer.writeAll("]");
	_ = allocator;
}

fn roundTrip(io: Io, allocator: Allocator, message: []const u8, quiet: bool) ![]u8 {
	const path = try proc.socketPath(io, allocator);

	var read_buffer: [1024 * 1024]u8 = undefined;
	var connection = sock.Connection.connect(path, &read_buffer) catch {
		if (quiet) return "";
		std.debug.print("yudaemond is not running\n", .{});
		return error.NotRunning;
	};
	defer connection.close();

	try connection.writeLine(message);

	var attempts: usize = 0;
	while (attempts < 8192) : (attempts += 1) {
		const line = try connection.readLine() orelse {
			std.debug.print("yudaemond sent no reply\n", .{});
			return error.NoReply;
		};

		const parsed = try json.parse(allocator, line);

		if (json.field(parsed.value, "ok") == null) continue;

		if (!json.flag(parsed.value, "ok")) {
			std.debug.print("yudae: {s}\n", .{json.textAt(parsed.value, "error")});
			return error.CallFailed;
		}

		const result = json.field(parsed.value, "result") orelse json.Value{ .null = {} };

		switch (result) {
			.null => return allocator.dupe(u8, "{}"),
			else => {},
		}

		var out: std.Io.Writer.Allocating = .init(allocator);
		try out.writer.print("{f}", .{std.json.fmt(result, .{})});
		return out.written();
	}

	return error.NoReply;
}

fn show(io: Io, body: []const u8) void {
	showDepth(io, body, 8);
}

fn showDepth(io: Io, body: []const u8, depth: usize) void {
	if (json_out) return printResult(io, body);

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const parsed = json.parse(allocator, body) catch return printResult(io, body);
	var out: std.Io.Writer.Allocating = .init(allocator);
	human.write(allocator, &out.writer, parsed.value, depth) catch return printResult(io, body);
	const text = std.mem.trimEnd(u8, out.written(), "\n");
	if (text.len > 0) printResult(io, text);
}

fn printResult(io: Io, body: []const u8) void {
	var buffer: [8192]u8 = undefined;
	var writer = std.Io.File.stdout().writer(io, &buffer);
	writer.interface.writeAll(body) catch {};
	writer.interface.writeAll("\n") catch {};
	writer.interface.flush() catch {};
}

fn writeArg(allocator: Allocator, writer: *std.Io.Writer, arg: []const u8) !void {
	if (json.parse(allocator, arg)) |_| {
		try writer.writeAll(arg);
	} else |_| {
		try std.json.Stringify.encodeJsonString(arg, .{}, writer);
	}
}


pub fn disk(io: Io, args: []const []const u8) !void {
	if (args.len < 3) {
		std.debug.print("usage: yudae disk scan|view|search|stat|mark|unmark|trash|remove|move|copy|rename|packages|uninstall|clean-packages|caches|clean [args...]\n", .{});
		std.process.exit(2);
	}

	const method = args[2];
	const rest = args[3..];

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	if (std.mem.eql(u8, method, "view") and rest.len == 0) {
		const body = try fetch(io);
		defer std.heap.smp_allocator.free(body);

		const parsed = json.parse(allocator, body) catch return error.StateUnreadable;
		const disk_state = json.field(parsed.value, "disk") orelse return error.NoDisk;

		var out: std.Io.Writer.Allocating = .init(allocator);
		try out.writer.print("{f}", .{std.json.fmt(disk_state, .{})});
		show(io, out.written());
		return;
	}

	const message = try diskMessage(allocator, method, rest);
	const result = roundTrip(io, allocator, message, false) catch std.process.exit(1);

	if (std.mem.eql(u8, method, "view")) {
		const body = try fetch(io);
		defer std.heap.smp_allocator.free(body);
		const parsed = json.parse(allocator, body) catch return error.StateUnreadable;
		const disk_state = json.field(parsed.value, "disk") orelse return error.NoDisk;
		var out: std.Io.Writer.Allocating = .init(allocator);
		try out.writer.print("{f}", .{std.json.fmt(disk_state, .{})});
		show(io, out.written());
		return;
	}

	if (result.len > 0 and !std.mem.eql(u8, result, "{}")) show(io, result);
}

fn diskMessage(allocator: Allocator, method: []const u8, rest: []const []const u8) ![]u8 {
	var out: std.Io.Writer.Allocating = .init(allocator);
	const w = &out.writer;

	try w.writeAll("{\"call\":{\"target\":\"disk\",\"method\":");
	try std.json.Stringify.encodeJsonString(method, .{}, w);
	try w.writeAll(",\"args\":{");

	if (std.mem.eql(u8, method, "scan")) {
		const path = if (rest.len > 0) rest[0] else "/";
		try w.writeAll("\"path\":");
		try std.json.Stringify.encodeJsonString(path, .{}, w);
	} else if (std.mem.eql(u8, method, "view")) {
		try w.writeAll("\"path\":");
		try std.json.Stringify.encodeJsonString(rest[0], .{}, w);
		if (rest.len > 1) {
			try w.writeAll(",\"depth\":");
			try w.writeAll(rest[1]);
		}
	} else if (std.mem.eql(u8, method, "search")) {
		try w.writeAll("\"query\":");
		try std.json.Stringify.encodeJsonString(if (rest.len > 0) rest[0] else "", .{}, w);
	} else if (std.mem.eql(u8, method, "stat") or std.mem.eql(u8, method, "mark") or std.mem.eql(u8, method, "unmark") or std.mem.eql(u8, method, "trash") or std.mem.eql(u8, method, "remove")) {
		const path = if (rest.len > 0) rest[0] else "";
		try w.writeAll("\"path\":");
		try std.json.Stringify.encodeJsonString(path, .{}, w);
	} else if (std.mem.eql(u8, method, "move") or std.mem.eql(u8, method, "copy") or std.mem.eql(u8, method, "rename")) {
		const from = if (rest.len > 0) rest[0] else "";
		const to = if (rest.len > 1) rest[1] else "";
		try w.writeAll("\"from\":");
		try std.json.Stringify.encodeJsonString(from, .{}, w);
		try w.writeAll(",\"to\":");
		try std.json.Stringify.encodeJsonString(to, .{}, w);
	} else if (std.mem.eql(u8, method, "uninstall")) {
		var yes = false;
		var names: std.ArrayList([]const u8) = .empty;
		for (rest) |arg| {
			if (std.mem.eql(u8, arg, "--yes")) {
				yes = true;
				continue;
			}
			try names.append(allocator, arg);
		}
		try w.writeAll("\"names\":[");
		for (names.items, 0..) |name, index| {
			if (index > 0) try w.writeAll(",");
			try std.json.Stringify.encodeJsonString(name, .{}, w);
		}
		try w.print("],\"confirm\":{s}", .{if (yes) "true" else "false"});
	} else if (std.mem.eql(u8, method, "clean-packages")) {
		var yes = false;
		for (rest) |arg| {
			if (std.mem.eql(u8, arg, "--yes")) yes = true;
		}
		try w.print("\"confirm\":{s}", .{if (yes) "true" else "false"});
	} else if (std.mem.eql(u8, method, "clean")) {
		var yes = false;
		var id: []const u8 = "all";
		for (rest) |arg| {
			if (std.mem.eql(u8, arg, "--yes")) {
				yes = true;
				continue;
			}
			id = arg;
		}
		try w.writeAll("\"id\":");
		try std.json.Stringify.encodeJsonString(id, .{}, w);
		try w.print(",\"confirm\":{s}", .{if (yes) "true" else "false"});
	} else if (std.mem.eql(u8, method, "packages") or std.mem.eql(u8, method, "caches")) {
		// no arguments
	} else if (std.mem.eql(u8, method, "watch")) {
		const path = if (rest.len > 0) rest[0] else "/";
		try w.writeAll("\"path\":");
		try std.json.Stringify.encodeJsonString(path, .{}, w);
		if (rest.len > 1) {
			try w.writeAll(",\"seconds\":");
			try w.writeAll(rest[1]);
		}
	} else if (std.mem.eql(u8, method, "app")) {
		// no arguments
	} else if (method.len == 0) {
		return error.UnknownMethod;
	} else {
		return error.UnknownMethod;
	}

	try w.writeAll("}}}");
	return out.written();
}

fn appName(name: []const u8) bool {
	if (name.len == 0 or name.len > 32) return false;
	for (name) |c| {
		if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
	}
	return true;
}

test "app names stay inside shell/app-<name>.qml" {
	try std.testing.expect(appName("settings"));
	try std.testing.expect(appName("kit-gallery2"));
	try std.testing.expect(!appName(""));
	try std.testing.expect(!appName("../etc"));
	try std.testing.expect(!appName("a\"b"));
	try std.testing.expect(!appName("Disk"));
}

pub fn app(io: Io, args: []const []const u8) !void {
	if (args.len < 4 or !std.mem.eql(u8, args[2], "open")) {
		std.debug.print("usage: yudae app open <name> [--vm <vm>] [--pane <pane>]\n", .{});
		std.process.exit(2);
	}

	const name = args[3];
	if (!appName(name)) {
		std.debug.print("yudae: app names are lowercase letters, digits and dashes\n", .{});
		std.process.exit(2);
	}
	var vm: []const u8 = "";
	var pane: []const u8 = "";
	var index: usize = 4;
	while (index < args.len) : (index += 1) {
		if (std.mem.eql(u8, args[index], "--vm") and index + 1 < args.len) {
			index += 1;
			vm = args[index];
		}
		if (std.mem.eql(u8, args[index], "--pane") and index + 1 < args.len) {
			index += 1;
			pane = args[index];
		}
	}

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();
	const repo = proc.repo(io, allocator);
	const class = try std.fmt.allocPrint(allocator, "com.yudae.{s}", .{name});

	if (vm.len > 0) {
		const view = try std.fmt.allocPrint(allocator,
			"{{\"call\":{{\"target\":\"vms\",\"method\":\"view\",\"args\":{{\"name\":\"{s}\"}}}}}}", .{vm});
		_ = roundTrip(io, allocator, view, true) catch {};
	}

	const listing = exec.run(io, allocator, &.{ "hyprctl", "clients", "-j" }) catch null;
	if (listing) |result| {
		defer result.deinit(allocator);
		if (std.mem.indexOf(u8, result.out, class) != null) {
			const focus = try std.fmt.allocPrint(allocator,
				"function() for _,w in ipairs(hl.get_windows()) do if w.class == \"{s}\" then hl.dispatch(hl.dsp.focus({{window=w}})) return end end end",
				.{class});
			const reply = hypr.request(io, allocator, focus) catch null;
			if (reply) |body| allocator.free(body);
			return;
		}
	}

	const entry = try std.fmt.allocPrint(allocator, "{s}/shell/app-{s}.qml", .{ repo, name });
	if (!proc.exists(io, entry)) {
		std.debug.print("yudae: no app {s}\n", .{name});
		std.process.exit(2);
	}
	const import_path = try std.fmt.allocPrint(allocator, "QML_IMPORT_PATH={s}/.local/lib/yudae/qml:{s}/shell/native/qml", .{ proc.home(io, allocator), repo });

	var argv: std.ArrayList([]const u8) = .empty;
	try argv.append(allocator, "setsid");
	try argv.append(allocator, "env");
	try argv.append(allocator, import_path);
	try argv.append(allocator, "QSG_RHI_BACKEND=opengl");
	try argv.append(allocator, try std.fmt.allocPrint(allocator, "YUDAE_APP={s}", .{name}));
	if (vm.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "YUDAE_VM={s}", .{vm}));
	if (pane.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "YUDAE_PANE={s}", .{pane}));
	try argv.append(allocator, "quickshell");
	try argv.append(allocator, "-p");
	try argv.append(allocator, entry);

	_ = exec.spawn(io, .{
		.argv = argv.items,
		.stdin = .ignore,
		.stdout = .ignore,
		.stderr = .ignore,
	}) catch return error.SpawnFailed;
}

pub fn spawnCheck(io: Io, args: []const []const u8) !void {
	var seconds: u64 = 5;
	var index: usize = 2;

	while (index < args.len) : (index += 1) {
		if (std.mem.eql(u8, args[index], "--seconds") and index + 1 < args.len) {
			index += 1;
			seconds = std.fmt.parseInt(u64, args[index], 10) catch 5;
		}
	}

	const before = try spawns(io);
	sleep.ms(seconds * 1000);
	const after = try spawns(io);

	if (before != after) {
		std.debug.print("idle spawns {d} -> {d} over {d}s\n", .{ before, after, seconds });
		std.process.exit(1);
	}

	var buffer: [256]u8 = undefined;
	const body = if (json_out)
		try std.fmt.bufPrint(&buffer, "{{\"before\":{d},\"after\":{d},\"seconds\":{d}}}", .{ before, after, seconds })
	else
		try std.fmt.bufPrint(&buffer, "idle spawns {d} -> {d} over {d}s", .{ before, after, seconds });
	printResult(io, body);
}

fn spawns(io: Io) !u64 {
	const body = try fetch(io);
	defer std.heap.smp_allocator.free(body);

	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();

	const parsed = json.parse(arena.allocator(), body) catch return error.StateUnreadable;
	const value = json.integer(json.deep(parsed.value, &.{ "daemon", "spawns" }));

	return @intCast(@max(value, 0));
}

pub fn print(io: Io, comptime message: []const u8) void {
	var buffer: [1024]u8 = undefined;
	var writer = std.Io.File.stdout().writer(io, &buffer);
	writer.interface.writeAll(message) catch {};
	writer.interface.flush() catch {};
}

test "cli module compiles" {
	try std.testing.expect(true);
}

pub fn settings(io: Io, args: []const []const u8) !void {
	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const message = settingsMessage(io, allocator, args) catch {
		std.debug.print("usage: yudae settings schema | get <key> | set <key> <value> | app [pane] | yudae bar layout <file>\n", .{});
		std.process.exit(2);
	};

	const result = roundTrip(io, allocator, message, false) catch std.process.exit(1);
	if (result.len > 0 and !std.mem.eql(u8, result, "{}")) show(io, result);
}

fn settingsMessage(io: Io, allocator: Allocator, args: []const []const u8) ![]u8 {
	if (args.len < 3) return error.Usage;

	var out: std.Io.Writer.Allocating = .init(allocator);
	const w = &out.writer;
	const target = args[1];
	const method = args[2];

	if (std.mem.eql(u8, target, "settings") and (std.mem.eql(u8, method, "schema") or std.mem.eql(u8, method, "get"))) {
		try w.writeAll("{\"call\":{\"target\":\"settings\",\"method\":");
		try std.json.Stringify.encodeJsonString(method, .{}, w);
		try w.writeAll(",\"args\":{");
		if (std.mem.eql(u8, method, "get") and args.len >= 4) {
			try w.writeAll("\"key\":");
			try std.json.Stringify.encodeJsonString(args[3], .{}, w);
		}
		try w.writeAll("}}}");
	} else if (std.mem.eql(u8, target, "settings") and std.mem.eql(u8, method, "set") and args.len == 5) {
		try w.writeAll("{\"call\":{\"target\":\"settings\",\"method\":\"set\",\"args\":{\"key\":");
		try std.json.Stringify.encodeJsonString(args[3], .{}, w);
		try w.writeAll(",\"value\":");
		if (json.parse(allocator, args[4])) |parsed| {
			try w.print("{f}", .{std.json.fmt(parsed.value, .{})});
		} else |_| {
			try std.json.Stringify.encodeJsonString(args[4], .{}, w);
		}
		try w.writeAll("}}}");
	} else if (std.mem.eql(u8, target, "settings") and std.mem.eql(u8, method, "app") and args.len <= 4) {
		try w.writeAll("{\"call\":{\"target\":\"settings\",\"method\":\"app\",\"args\":{\"pane\":");
		try std.json.Stringify.encodeJsonString(if (args.len == 4) args[3] else "", .{}, w);
		try w.writeAll("}}}");
	} else if (std.mem.eql(u8, target, "bar") and std.mem.eql(u8, method, "layout") and args.len == 4) {
		const body = try proc.readFile(io, allocator, args[3]);
		const parsed = try json.parse(allocator, body);
		try w.print("{{\"call\":{{\"target\":\"bar\",\"method\":\"layout\",\"args\":{{\"layout\":{f}}}}}}}", .{std.json.fmt(parsed.value, .{})});
	} else return error.Usage;

	return out.written();
}

test "settings and bar verbs build their calls" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	const io = std.testing.io;

	try std.testing.expectEqualStrings(
		"{\"call\":{\"target\":\"settings\",\"method\":\"set\",\"args\":{\"key\":\"barStatSpacing\",\"value\":16}}}",
		try settingsMessage(io, a, &.{ "yudae", "settings", "set", "barStatSpacing", "16" }),
	);
	try std.testing.expectEqualStrings(
		"{\"call\":{\"target\":\"settings\",\"method\":\"set\",\"args\":{\"key\":\"popupPos\",\"value\":\"top-left\"}}}",
		try settingsMessage(io, a, &.{ "yudae", "settings", "set", "popupPos", "top-left" }),
	);
	try std.testing.expectEqualStrings(
		"{\"call\":{\"target\":\"settings\",\"method\":\"app\",\"args\":{\"pane\":\"\"}}}",
		try settingsMessage(io, a, &.{ "yudae", "settings", "app" }),
	);
	try std.testing.expectError(error.Usage, settingsMessage(io, a, &.{ "yudae", "settings", "set", "barStatSpacing" }));
	try std.testing.expectEqualStrings(
		"{\"call\":{\"target\":\"settings\",\"method\":\"schema\",\"args\":{}}}",
		try settingsMessage(io, a, &.{ "yudae", "settings", "schema" }),
	);
	try std.testing.expectEqualStrings(
		"{\"call\":{\"target\":\"settings\",\"method\":\"get\",\"args\":{\"key\":\"barStatSpacing\"}}}",
		try settingsMessage(io, a, &.{ "yudae", "settings", "get", "barStatSpacing" }),
	);
	try std.testing.expectError(error.Usage, settingsMessage(io, a, &.{ "yudae", "bar", "nope" }));
}
