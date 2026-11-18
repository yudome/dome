const std = @import("std");
const hubmod = @import("../hub.zig");
const appsmod = @import("apps.zig");
const iconsmod = @import("../primitives/icons.zig");
const json = @import("../primitives/json.zig");
const sleep = @import("../primitives/sleep.zig");
const proc = @import("../primitives/proc.zig");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Hub = hubmod.Hub;

const Pending = struct { key: []u8, value: []u8 };

const max_asked = 4000;
const rescan_ms = 300_000;
const theme_settle_ms = 300;

pub const Icons = struct {
	allocator: Allocator,
	io: Io,
	hub: *Hub,
	mutex: std.Io.Mutex = .init,
	scratch: std.heap.ArenaAllocator,
	resolver: *iconsmod.Icons,
	asked: std.StringHashMapUnmanaged([]u8) = .empty,
	names: std.StringHashMapUnmanaged([]u8) = .empty,
	theme_buf: [128]u8 = undefined,
	theme_len: usize = 0,
	apps: ?*appsmod.Apps = null,

	pub fn create(allocator: Allocator, io: Io, hub: *Hub, resolver: *iconsmod.Icons) !*Icons {
		const self = try allocator.create(Icons);
		self.* = .{
			.allocator = allocator,
			.io = io,
			.hub = hub,
			.scratch = std.heap.ArenaAllocator.init(allocator),
			.resolver = resolver,
		};

		return self;
	}

	pub fn provider(self: *Icons) hubmod.Provider {
		return .{ .key = "icons", .ctx = self, .render = renderThunk };
	}

	fn renderThunk(ctx: *anyopaque, writer: *Writer) anyerror!void {
		const self: *Icons = @ptrCast(@alignCast(ctx));
		try self.render(writer);
	}

	pub fn attach(self: *Icons, apps: *appsmod.Apps) void {
		self.apps = apps;
		apps.onChange(self, appsChanged);
	}

	pub fn start(self: *Icons) !void {
		self.resolver.scan();
		_ = self.readTheme();
		self.warm(true);

		const thread = try std.Thread.spawn(.{}, loop, .{self});
		thread.detach();
		if (std.Thread.spawn(.{}, watchTheme, .{self})) |watcher| watcher.detach() else |_| {}
	}

	fn configDir(self: *Icons, buf: []u8) ![]const u8 {
		if (proc.env(self.io, self.allocator, "XDG_CONFIG_HOME")) |dir| return std.fmt.bufPrint(buf, "{s}", .{dir});
		return std.fmt.bufPrint(buf, "{s}/.config", .{proc.home(self.io, self.allocator)});
	}

	fn readTheme(self: *Icons) bool {
		var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
		var path_buf: [std.fs.max_path_bytes]u8 = undefined;
		const dir = self.configDir(&dir_buf) catch return false;
		const path = std.fmt.bufPrint(&path_buf, "{s}/kdeglobals", .{dir}) catch return false;
		const body = proc.readFile(self.io, self.allocator, path) catch "";
		defer if (body.len > 0) self.allocator.free(body);
		const theme = themeOf(body);

		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		if (theme.len > self.theme_buf.len or std.mem.eql(u8, theme, self.theme_buf[0..self.theme_len])) return false;
		@memcpy(self.theme_buf[0..theme.len], theme);
		self.theme_len = theme.len;
		return true;
	}

	fn watchTheme(self: *Icons) void {
		var dir_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
		const dir = self.configDir(dir_buf[0..std.fs.max_path_bytes]) catch return;
		dir_buf[dir.len] = 0;
		const fd = linux.inotify_init1(linux.IN.CLOEXEC);
		if (linux.errno(fd) != .SUCCESS) return;
		const watch = linux.inotify_add_watch(@intCast(fd), dir_buf[0..dir.len :0], linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE);
		if (linux.errno(watch) != .SUCCESS) return;

		var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
		while (true) {
			const read = linux.read(@intCast(fd), &buffer, buffer.len);
			if (linux.errno(read) == .INTR) continue;
			if (linux.errno(read) != .SUCCESS or read == 0) return;
			if (!mentions(buffer[0..read], "kdeglobals")) continue;
			// ponytail: a fixed settle delay so KDE's own icon reload lands before the shell asks again; an explicit KIconLoader dbus hook would be exact
			sleep.ms(theme_settle_ms);
			if (self.readTheme()) self.hub.publish();
		}
	}

	fn appsChanged(ctx: *anyopaque) void {
		const self: *Icons = @ptrCast(@alignCast(ctx));

		self.resolver.scan();
		self.warm(true);

		sleep.ms(3000);

		self.resolver.scan();
		self.warm(true);
	}

	fn loop(self: *Icons) void {
		while (true) {
			sleep.ms(rescan_ms);
			self.resolver.scan();
			self.warm(true);
		}
	}

	fn holds(self: *Icons, key: []const u8, value: []const u8) bool {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		const found = self.asked.get(key) orelse return false;

		return std.mem.eql(u8, found, value);
	}

	fn known(self: *Icons, key: []const u8) bool {
		self.mutex.lockUncancelable(self.io);
		const found = self.asked.contains(key);
		self.mutex.unlock(self.io);

		return found;
	}

	fn collect(self: *Icons, entries: []const appsmod.Entry, pending: *std.ArrayListUnmanaged(Pending)) void {
		const urls = self.allocator.alloc(?[]u8, entries.len) catch return;

		defer {
			for (urls) |url| {
				if (url) |value| self.allocator.free(value);
			}

			self.allocator.free(urls);
		}

		for (entries, 0..) |entry, index| {
			urls[index] = null;
			if (entry.id.len == 0) continue;

			const hit = self.resolver.lookup(entry.id);
			self.remember(entry.id, hit.name);
			self.remember(entry.name, hit.name);
			const path = hit.path;
			urls[index] = if (path.len > 0)
				std.fmt.allocPrint(self.allocator, "file://{s}", .{path}) catch continue
			else
				self.allocator.dupe(u8, "") catch continue;
		}

		for (entries, 0..) |entry, index| {
			if (urls[index]) |url| self.add(pending, entry.id, url);
		}

		for (entries, 0..) |entry, index| {
			if (urls[index]) |url| self.add(pending, entry.name, url);
		}
	}

	fn add(self: *Icons, pending: *std.ArrayListUnmanaged(Pending), name: []const u8, value: []const u8) void {
		const cleaned = cleanName(name);
		if (cleaned.len == 0) return;
		if (self.holds(cleaned, value)) return;

		const key = self.allocator.dupe(u8, cleaned) catch return;
		const copy = self.allocator.dupe(u8, value) catch {
			self.allocator.free(key);
			return;
		};

		pending.append(self.allocator, .{ .key = key, .value = copy }) catch {
			self.allocator.free(key);
			self.allocator.free(copy);
		};
	}

	fn merge(self: *Icons, pending: *std.ArrayListUnmanaged(Pending)) bool {
		if (pending.items.len == 0) return false;

		var changed = false;

		self.mutex.lockUncancelable(self.io);

		for (pending.items) |*entry| {
			if (self.asked.getEntry(entry.key)) |found| {
				if (!std.mem.eql(u8, found.value_ptr.*, entry.value)) {
					self.allocator.free(found.value_ptr.*);
					found.value_ptr.* = entry.value;
					entry.value = &.{};
					changed = true;
				}
			} else {
				self.asked.put(self.allocator, entry.key, entry.value) catch continue;
				entry.key = &.{};
				entry.value = &.{};
				changed = true;
			}
		}

		self.mutex.unlock(self.io);

		return changed;
	}

	fn warm(self: *Icons, publish: bool) void {
		const apps = self.apps orelse return;

		self.resolver.ensure();

		var pending: std.ArrayListUnmanaged(Pending) = .empty;

		defer {
			for (pending.items) |entry| {
				self.allocator.free(entry.key);
				self.allocator.free(entry.value);
			}

			pending.deinit(self.allocator);
		}

		const ctx = struct {
			self: *Icons,
			pending: *std.ArrayListUnmanaged(Pending),

			fn run(state: @This(), entries: []const appsmod.Entry) void {
				state.self.collect(entries, state.pending);
			}
		}{ .self = self, .pending = &pending };

		apps.view(ctx, @TypeOf(ctx).run);

		if (self.merge(&pending) and publish) self.hub.publish();
	}

	pub fn want(self: *Icons, name: []const u8) void {
		const trimmed = cleanName(name);
		if (trimmed.len == 0) return;

		self.mutex.lockUncancelable(self.io);
		const found = self.asked.contains(trimmed);
		const full = self.asked.count() >= max_asked;
		self.mutex.unlock(self.io);

		if (found or full) return;

		self.resolveName(name, trimmed);
	}

	pub fn wantPid(self: *Icons, pid: i64) void {
		if (pid <= 0) return;

		const key = std.fmt.allocPrint(self.allocator, "pid:{d}", .{pid}) catch return;
		defer self.allocator.free(key);

		if (self.known(key)) return;

		const hit = self.resolver.lookupPid(pid);
		self.remember(key, hit.name);
		const path = hit.path;
		const url = if (path.len > 0) std.fmt.allocPrint(self.allocator, "file://{s}", .{path}) catch "" else "";
		defer if (url.len > 0) self.allocator.free(url);

		self.store(key, url);
	}

	fn resolveName(self: *Icons, raw: []const u8, name: []const u8) void {
		const hit = self.resolver.lookup(name);
		self.remember(name, hit.name);
		const alias_name = std.mem.trim(u8, raw, " \t\r\n");
		if (!std.mem.eql(u8, alias_name, name)) self.remember(alias_name, hit.name);
		const path = hit.path;
		const url = if (path.len > 0) std.fmt.allocPrint(self.allocator, "file://{s}", .{path}) catch "" else "";
		defer if (url.len > 0) self.allocator.free(url);

		self.store(name, url);

		const alias = std.mem.trim(u8, raw, " \t\r\n");
		if (!std.mem.eql(u8, alias, name)) self.store(alias, url);
	}

	fn remember(self: *Icons, key: []const u8, icon: []const u8) void {
		const cleaned = cleanName(key);
		if (cleaned.len == 0 or icon.len == 0) return;

		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		if (self.names.getPtr(cleaned)) |value| {
			if (std.mem.eql(u8, value.*, icon)) return;
			const copy = self.allocator.dupe(u8, icon) catch return;
			self.allocator.free(value.*);
			value.* = copy;
			return;
		}

		const key_copy = self.allocator.dupe(u8, cleaned) catch return;
		const value_copy = self.allocator.dupe(u8, icon) catch {
			self.allocator.free(key_copy);
			return;
		};
		self.names.put(self.allocator, key_copy, value_copy) catch {
			self.allocator.free(key_copy);
			self.allocator.free(value_copy);
		};
	}

	fn store(self: *Icons, key: []const u8, value: []const u8) void {
		self.mutex.lockUncancelable(self.io);

		const entry = self.asked.getEntry(key);
		var changed = false;

		if (entry) |found| {
			if (!std.mem.eql(u8, found.value_ptr.*, value)) {
				self.allocator.free(found.value_ptr.*);
				found.value_ptr.* = self.allocator.dupe(u8, value) catch "";
				changed = true;
			}
		} else {
			const key_copy = self.allocator.dupe(u8, key) catch {
				self.mutex.unlock(self.io);
				return;
			};
			const value_copy = self.allocator.dupe(u8, value) catch {
				self.allocator.free(key_copy);
				self.mutex.unlock(self.io);
				return;
			};

			self.asked.put(self.allocator, key_copy, value_copy) catch {
				self.allocator.free(key_copy);
				self.allocator.free(value_copy);
			};

			changed = true;
		}

		self.mutex.unlock(self.io);

		if (changed) self.hub.publish();
	}

	fn render(self: *Icons, writer: *Writer) !void {
		self.warm(false);

		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);

		_ = self.scratch.reset(.retain_capacity);
		const arena = self.scratch.allocator();

		try writer.writeAll("{\"map\":{");

		var it = self.asked.iterator();
		var first = true;

		while (it.next()) |entry| {
			if (!first) try writer.writeAll(",");
			first = false;

			try json.write(writer, entry.key_ptr.*);
			try writer.writeAll(":");
			try json.write(writer, entry.value_ptr.*);
		}

		try writer.writeAll("},\"theme\":");
		try json.write(writer, self.theme_buf[0..self.theme_len]);
		try writer.writeAll(",\"names\":{");

		var names = self.names.iterator();
		first = true;

		while (names.next()) |entry| {
			if (!first) try writer.writeAll(",");
			first = false;

			try json.write(writer, entry.key_ptr.*);
			try writer.writeAll(":");
			try json.write(writer, entry.value_ptr.*);
		}

		try writer.writeAll("}}");

		_ = arena;
	}
};

fn mentions(bytes: []const u8, wanted: []const u8) bool {
	var offset: usize = 0;
	while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
		const event: *align(1) const linux.inotify_event = @ptrCast(&bytes[offset]);
		const start = offset + @sizeOf(linux.inotify_event);
		offset = start + event.len;
		const name = std.mem.sliceTo(bytes[start..@min(offset, bytes.len)], 0);
		if (std.mem.eql(u8, name, wanted)) return true;
	}
	return false;
}

fn themeOf(body: []const u8) []const u8 {
	var in_icons = false;
	var lines = std.mem.splitScalar(u8, body, '\n');
	while (lines.next()) |raw| {
		const line = std.mem.trim(u8, raw, " \t\r");
		if (line.len > 0 and line[0] == '[') {
			in_icons = std.mem.eql(u8, line, "[Icons]");
			continue;
		}
		if (!in_icons) continue;
		const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		if (std.mem.eql(u8, std.mem.trim(u8, line[0..split], " \t"), "Theme")) return std.mem.trim(u8, line[split + 1 ..], " \t");
	}
	return "";
}

test "the icon theme is read from the Icons group only" {
	try std.testing.expectEqualStrings("Papirus", themeOf("[General]\nTheme=nope\n\n[Icons]\nTheme = Papirus\n[KDE]\nTheme=other\n"));
	try std.testing.expectEqualStrings("", themeOf("[General]\nTheme=nope\n"));
	try std.testing.expectEqualStrings("", themeOf(""));
}

pub fn cleanName(name: []const u8) []const u8 {
	const trimmed = std.mem.trim(u8, name, " \t\r\n");

	if (std.mem.endsWith(u8, trimmed, ".desktop")) return trimmed[0 .. trimmed.len - ".desktop".len];

	return trimmed;
}

test "names are trimmed and lose their desktop suffix" {
	try std.testing.expectEqualStrings("Dolphin", cleanName("  Dolphin.desktop \t"));
	try std.testing.expectEqualStrings("Dolphin", cleanName("Dolphin"));
	try std.testing.expectEqualStrings("org.kde.dolphin", cleanName("org.kde.dolphin"));
	try std.testing.expectEqualStrings("Cyberpunk 2077", cleanName(" Cyberpunk 2077 "));
	try std.testing.expectEqualStrings("", cleanName(" \n\t "));
}

test "every app entry is resolved before the map is ever asked" {
	const io = std.Io.Threaded.global_single_threaded.io();
	const allocator = std.testing.allocator;

	var hub: hubmod.Hub = .{ .allocator = allocator, .io = io };
	const resolver = try iconsmod.Icons.create(allocator, io);
	defer allocator.destroy(resolver);

	resolver.scanned_at = 1;
	try resolver.files.put(allocator, try allocator.dupe(u8, "top"), try allocator.dupe(u8, "/icons/top.svg"));
	defer {
		var it = resolver.files.iterator();
		while (it.next()) |entry| {
			allocator.free(entry.key_ptr.*);
			allocator.free(entry.value_ptr.*);
		}
		resolver.files.deinit(allocator);
	}

	const self = try Icons.create(allocator, io, &hub, resolver);
	defer {
		var it = self.asked.iterator();
		while (it.next()) |entry| {
			allocator.free(entry.key_ptr.*);
			allocator.free(entry.value_ptr.*);
		}
		self.asked.deinit(allocator);
		var names = self.names.iterator();
		while (names.next()) |entry| {
			allocator.free(entry.key_ptr.*);
			allocator.free(entry.value_ptr.*);
		}
		self.names.deinit(allocator);
		self.scratch.deinit();
		allocator.destroy(self);
	}

	const entries = [_]appsmod.Entry{
		.{ .id = @constCast("top"), .name = @constCast("Top"), .icon = @constCast("top"), .exec = @constCast("top"), .command = @constCast("top") },
		.{ .id = @constCast("missing"), .name = @constCast("Missing"), .icon = @constCast("nope"), .exec = @constCast("missing"), .command = @constCast("missing") },
	};

	var pending: std.ArrayListUnmanaged(Pending) = .empty;
	defer {
		for (pending.items) |entry| {
			allocator.free(entry.key);
			allocator.free(entry.value);
		}
		pending.deinit(allocator);
	}

	self.collect(&entries, &pending);
	try std.testing.expectEqual(@as(usize, 4), pending.items.len);
	try std.testing.expect(self.merge(&pending));

	try std.testing.expectEqualStrings("file:///icons/top.svg", self.asked.get("top").?);
	try std.testing.expectEqualStrings("file:///icons/top.svg", self.asked.get("Top").?);
	try std.testing.expectEqualStrings("", self.asked.get("missing").?);
	try std.testing.expectEqualStrings("", self.asked.get("Missing").?);
	try std.testing.expectEqualStrings("top", self.names.get("top").?);
	try std.testing.expectEqualStrings("top", self.names.get("Top").?);
	try std.testing.expect(self.names.get("missing") == null);

	var again: std.ArrayListUnmanaged(Pending) = .empty;
	defer again.deinit(allocator);

	self.collect(&entries, &again);
	try std.testing.expectEqual(@as(usize, 0), again.items.len);
}
