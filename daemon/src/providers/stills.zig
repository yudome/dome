const std = @import("std");
const json = @import("../primitives/json.zig");
const proc = @import("../primitives/proc.zig");
const wayland = @import("../primitives/wayland.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const cache_file = "dotfiles/cache/.shell/wallpaper-videos.json";

/// What a video settles on: the analysed pick, unless the user saved their own.
pub const Entry = struct {
	mtime: i64 = 0,
	size: i64 = 0,
	frame: f64 = 0,
	settle_ms: i64 = 1200,
	curve: f64 = 3,
	top: f64 = -1,
	rest: f64 = -1,
	analysed: bool = false,

	pub fn still(self: Entry) f64 {
		return if (self.rest >= 0) self.rest else self.frame;
	}
};

pub const Hook = struct {
	ctx: *anyopaque,
	run: *const fn (ctx: *anyopaque) void,
};

/// Per-video still frame picks, analysed once in the background and cached by mtime and size.
pub const Stills = struct {
	allocator: Allocator,
	io: Io,
	mutex: std.Io.Mutex = .init,
	entries: std.StringHashMapUnmanaged(Entry) = .empty,
	queue: std.ArrayListUnmanaged([]u8) = .empty,
	working: bool = false,
	active: ?[]u8 = null,
	analysed: ?Hook = null,

	pub fn create(allocator: Allocator, io: Io) !*Stills {
		const self = try allocator.create(Stills);
		self.* = .{ .allocator = allocator, .io = io };
		self.load();
		return self;
	}

	pub fn get(self: *Stills, path: []const u8) Entry {
		const stamp = stampOf(self.io, path) orelse return .{};
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		const entry = self.entries.get(path) orelse return .{};
		if (entry.mtime != stamp.mtime or entry.size != stamp.size) return .{ .rest = entry.rest };
		return entry;
	}

	/// Saves the user's still frame for `path`; the renderer shows it right away if it is on screen.
	pub fn setRest(self: *Stills, path: []const u8, seconds: f64) void {
		const stamp = stampOf(self.io, path) orelse return;
		self.mutex.lockUncancelable(self.io);
		const slot = self.entryFor(path) orelse {
			self.mutex.unlock(self.io);
			return;
		};
		slot.rest = seconds;
		if (slot.mtime != stamp.mtime or slot.size != stamp.size) {
			slot.* = .{ .rest = seconds };
		}
		self.mutex.unlock(self.io);
		self.save();
	}

	/// Queues every video in `paths` that has no pick for its current mtime and size.
	pub fn scan(self: *Stills, paths: []const []const u8) void {
		self.mutex.lockUncancelable(self.io);
		for (paths) |path| {
			if (!wayland.isVideoName(path)) continue;
			const stamp = stampOf(self.io, path) orelse continue;
			if (self.entries.get(path)) |entry| {
				if (entry.analysed and entry.mtime == stamp.mtime and entry.size == stamp.size) continue;
			}
			for (self.queue.items) |queued| {
				if (std.mem.eql(u8, queued, path)) break;
			} else {
				const copy = self.allocator.dupe(u8, path) catch continue;
				self.queue.append(self.allocator, copy) catch self.allocator.free(copy);
			}
		}
		const start = !self.working and self.queue.items.len > 0;
		if (start) self.working = true;
		self.mutex.unlock(self.io);

		if (!start) return;
		const thread = std.Thread.spawn(.{}, work, .{self}) catch {
			self.mutex.lockUncancelable(self.io);
			self.working = false;
			self.mutex.unlock(self.io);
			return;
		};
		thread.detach();
	}

	pub fn setActive(self: *Stills, path: []const u8) void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		if (self.active) |old| self.allocator.free(old);
		self.active = self.allocator.dupe(u8, path) catch null;
	}

	fn work(self: *Stills) void {
		while (true) {
			self.mutex.lockUncancelable(self.io);
			const next = self.queue.pop();
			if (next == null) self.working = false;
			self.mutex.unlock(self.io);

			const path = next orelse return;
			defer self.allocator.free(path);
			self.analyse(path);
		}
	}

	fn analyse(self: *Stills, path: []const u8) void {
		const stamp = stampOf(self.io, path) orelse return;
		const z = self.allocator.dupeSentinel(u8, path, 0) catch return;
		defer self.allocator.free(z);

		const pick = wayland.analyse(z) orelse {
			std.debug.print("yudaemond: still pick failed for {s}\n", .{path});
			return;
		};
		std.debug.print("yudaemond: still pick {s} frame={d:.3}s settle={d}ms curve={d} over {d} frames\n", .{ path, pick.frame, pick.settle_ms, pick.curve, pick.frames });

		self.mutex.lockUncancelable(self.io);
		const slot = self.entryFor(path);
		var follow = false;
		if (slot) |entry| {
			const rest = if (entry.mtime == stamp.mtime and entry.size == stamp.size) entry.rest else -1;
			entry.* = .{
				.mtime = stamp.mtime,
				.size = stamp.size,
				.frame = pick.frame,
				.settle_ms = pick.settle_ms,
				.curve = pick.curve,
				.top = pick.top,
				.rest = rest,
				.analysed = true,
			};
			follow = rest < 0 and self.active != null and std.mem.eql(u8, self.active.?, path);
		}
		self.mutex.unlock(self.io);

		self.save();
		if (follow) wayland.still(pick.frame);
		if (self.analysed) |hook| hook.run(hook.ctx);
	}

	fn entryFor(self: *Stills, path: []const u8) ?*Entry {
		const found = self.entries.getOrPut(self.allocator, path) catch return null;
		if (!found.found_existing) {
			found.key_ptr.* = self.allocator.dupe(u8, path) catch {
				self.entries.removeByPtr(found.key_ptr);
				return null;
			};
			found.value_ptr.* = .{};
		}
		return found.value_ptr;
	}

	fn load(self: *Stills) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const allocator = arena.allocator();

		const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ proc.home(self.io, allocator), cache_file }) catch return;
		const raw = proc.readFile(self.io, allocator, path) catch return;
		const parsed = json.parse(allocator, raw) catch return;
		const files = json.field(parsed.value, "files") orelse return;
		if (files != .object) return;

		var it = files.object.iterator();
		while (it.next()) |item| {
			const entry = entryOf(item.value_ptr.*);
			const slot_ptr = self.entryFor(item.key_ptr.*) orelse continue;
			slot_ptr.* = entry;
		}
	}

	fn save(self: *Stills) void {
		var arena = std.heap.ArenaAllocator.init(self.allocator);
		defer arena.deinit();
		const allocator = arena.allocator();

		var buffer: Writer.Allocating = .init(allocator);
		self.mutex.lockUncancelable(self.io);
		writeAll(&buffer.writer, &self.entries) catch {
			self.mutex.unlock(self.io);
			return;
		};
		self.mutex.unlock(self.io);

		const dir = std.fmt.allocPrint(allocator, "{s}/dotfiles/cache/.shell", .{proc.home(self.io, allocator)}) catch return;
		std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
		const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ proc.home(self.io, allocator), cache_file }) catch return;
		proc.writeFileAtomic(self.io, self.allocator, path, buffer.written()) catch return;
	}
};

const Stamp = struct { mtime: i64, size: i64 };

fn stampOf(io: Io, path: []const u8) ?Stamp {
	const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
	return .{ .mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)), .size = @intCast(stat.size) };
}

fn entryOf(value: json.Value) Entry {
	return .{
		.mtime = json.integer(json.field(value, "mtime")),
		.size = json.integer(json.field(value, "size")),
		.frame = json.numberAt(value, "frame"),
		.settle_ms = std.math.clamp(json.integer(json.field(value, "settleMs")), 600, 2500),
		.curve = std.math.clamp(json.numberAt(value, "curve"), 1, 6),
		.top = if (json.field(value, "top") != null) json.numberAt(value, "top") else -1,
		.rest = if (json.field(value, "restFrame") != null) json.numberAt(value, "restFrame") else -1,
		.analysed = json.flag(value, "analysed"),
	};
}

fn writeAll(writer: *Writer, entries: *const std.StringHashMapUnmanaged(Entry)) !void {
	try writer.writeAll("{\"files\":{");
	var first = true;
	var it = entries.iterator();
	while (it.next()) |item| {
		if (!first) try writer.writeAll(",");
		first = false;
		try json.write(writer, item.key_ptr.*);
		const e = item.value_ptr.*;
		try writer.print(":{{\"mtime\":{d},\"size\":{d},\"frame\":{d},\"settleMs\":{d},\"curve\":{d},\"top\":{d},\"analysed\":{s}", .{ e.mtime, e.size, e.frame, e.settle_ms, e.curve, e.top, if (e.analysed) "true" else "false" });
		if (e.rest >= 0) try writer.print(",\"restFrame\":{d}", .{e.rest});
		try writer.writeAll("}");
	}
	try writer.writeAll("}}");
}

test "a cached pick survives the round trip and the user's frame wins" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();

	var entries: std.StringHashMapUnmanaged(Entry) = .empty;
	try entries.put(a, "/v/a.mp4", .{ .mtime = 5, .size = 9, .frame = 2.5, .settle_ms = 900, .curve = 2, .top = 0.4, .rest = 3.25, .analysed = true });

	var buffer: Writer.Allocating = .init(a);
	try writeAll(&buffer.writer, &entries);
	const parsed = try json.parse(a, buffer.written());
	const back = entryOf(json.field(json.field(parsed.value, "files").?, "/v/a.mp4").?);

	try std.testing.expectEqual(@as(i64, 9), back.size);
	try std.testing.expectEqual(@as(f64, 2.5), back.frame);
	try std.testing.expectEqual(@as(i64, 900), back.settle_ms);
	try std.testing.expectEqual(@as(f64, 3.25), back.still());
	try std.testing.expect(back.analysed);

	const plain: Entry = .{ .frame = 1.5 };
	try std.testing.expectEqual(@as(f64, 1.5), plain.still());
}
