const std = @import("std");
const linux = std.os.linux;
const guard = @import("../disk/guard.zig");
const proc = @import("../../primitives/proc.zig");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const none = index.none;
const dir_bit = index.dir_bit;
const tag_bi = index.tag_bi;
const tag_uni = index.tag_uni;
const max_threads = 8;
const batch_dirs = 64;
const buckets = 256 + 65536 + (1 << 18);

const skipped_paths = [_][]const u8{ "/tmp", "/var", "/opt", "/nix", "/snap", "/lost+found" };
const skipped_names = [_][]const u8{ "node_modules", "__pycache__", "zig-out" };

pub fn skipName(name: []const u8) bool {
	for (skipped_names) |junk| if (std.mem.eql(u8, name, junk)) return true;
	return false;
}

fn skipPath(full: []const u8) bool {
	for (guard.protected_paths ++ skipped_paths) |prefix| if (std.mem.eql(u8, full, prefix)) return true;
	return false;
}

pub const Entries = struct {
	fd: i32,
	buffer: [32 * 1024]u8 = undefined,
	len: usize = 0,
	at: usize = 0,

	pub fn open(path: [*:0]const u8) ?Entries {
		const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
		return if (linux.errno(fd) == .SUCCESS) .{ .fd = @intCast(fd) } else null;
	}

	pub fn close(self: *Entries) void {
		_ = linux.close(self.fd);
	}

	pub fn next(self: *Entries) ?*align(1) linux.dirent64 {
		if (self.at >= self.len) {
			const read = linux.getdents64(self.fd, &self.buffer, self.buffer.len);
			if (linux.errno(read) != .SUCCESS or read == 0) return null;
			self.len = read;
			self.at = 0;
		}
		const entry: *align(1) linux.dirent64 = @ptrCast(&self.buffer[self.at]);
		if (entry.reclen == 0) return null;
		self.at += entry.reclen;
		return entry;
	}
};

pub fn nameOf(entry: *align(1) linux.dirent64) []const u8 {
	return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
}

const Crew = struct {
	io: Io,
	ctx: *anyopaque = undefined,
	job: *const fn (*anyopaque, usize) anyerror!void,
	size: usize,
	threads: [max_threads]?std.Thread = @splat(null),
	start: [max_threads]std.Io.Semaphore = @splat(.{}),
	done: std.Io.Semaphore = .{},
	busy: bool = false,
	stop: bool = false,
	failed: bool = false,

	fn spawn(self: *Crew, ctx: *anyopaque) void {
		self.ctx = ctx;
		for (self.threads[0..self.size], 0..) |*thread, i| thread.* = std.Thread.spawn(.{}, loop, .{ self, i }) catch null;
	}

	fn loop(self: *Crew, i: usize) void {
		while (true) {
			self.start[i].waitUncancelable(self.io);
			if (@atomicLoad(bool, &self.stop, .acquire)) return;
			self.run(i);
			self.done.post(self.io);
		}
	}

	fn run(self: *Crew, i: usize) void {
		self.job(self.ctx, i) catch @atomicStore(bool, &self.failed, true, .release);
	}

	fn go(self: *Crew) void {
		self.busy = true;
		for (self.threads[0..self.size], 0..) |thread, i| if (thread == null) self.run(i) else self.start[i].post(self.io);
	}

	fn wait(self: *Crew) !void {
		if (self.busy) for (self.threads[0..self.size]) |thread| if (thread != null) self.done.waitUncancelable(self.io);
		self.busy = false;
		if (@atomicLoad(bool, &self.failed, .acquire)) return error.CrewFailed;
	}

	fn shutdown(self: *Crew) void {
		@atomicStore(bool, &self.stop, true, .release);
		for (self.threads[0..self.size], 0..) |thread, i| if (thread) |t| {
			self.start[i].post(self.io);
			t.join();
		};
	}
};

const chunk_data = 28;

const Chunk = extern struct {
	data: [chunk_data]u8,
	next: u32,
};

const Slot = struct {
	gram: u32,
	last: u32 = 0,
	count: u32 = 0,
	len: u32 = 0,
	head: u32 = none,
	tail: u32 = none,
	used: u8 = chunk_data,
};

const Poster = struct {
	allocator: Allocator,
	tri: bool,
	slots: std.ArrayList(Slot) = .empty,
	chunks: std.ArrayList(Chunk) = .empty,
	slot_of: []u32 = &.{},
	seen: [buckets / 64]u64 = @splat(0),
	touched: std.ArrayList(u32) = .empty,
	unit: u32 = 0,

	fn deinit(self: *Poster) void {
		self.slots.deinit(self.allocator);
		self.chunks.deinit(self.allocator);
		self.touched.deinit(self.allocator);
		self.allocator.free(self.slot_of);
	}

	fn feed(self: *Poster, bytes: []const u8) !void {
		var at: usize = 0;
		while (at < bytes.len) {
			const block = std.mem.readInt(u32, bytes[at..][0..4], .little);
			const text = bytes[at + 5 ..][0..bytes[at + 4]];
			at += 5 + text.len;
			const unit = if (self.tri) block else block / index.coarse;
			if (unit != self.unit) try self.flush(unit);
			var i: usize = 0;
			if (self.tri) {
				while (i + 3 <= text.len) : (i += 1) try self.mark(index.triOf(text[i..][0..3]));
				continue;
			}
			if (text.len == 1) try self.mark(tag_uni | text[0]);
			while (i + 2 <= text.len) : (i += 1) try self.mark(tag_bi | @as(u32, text[i]) << 8 | text[i + 1]);
		}
	}

	fn bucket(gram: u32) u32 {
		return if (gram >= tag_uni) gram - tag_uni else if (gram >= tag_bi) 256 + (gram - tag_bi) else 256 + 65536 + gram;
	}

	fn mark(self: *Poster, gram: u32) !void {
		const bit = bucket(gram);
		const mask = @as(u64, 1) << @intCast(bit & 63);
		if (self.seen[bit >> 6] & mask != 0) return;
		self.seen[bit >> 6] |= mask;
		try self.touched.append(self.allocator, gram);
	}

	fn flush(self: *Poster, next: u32) !void {
		for (0..self.touched.items.len) |at| {
			const gram = self.touched.items[at];
			if (gram < tag_bi or gram >= tag_uni) continue;
			try self.mark(tag_uni | ((gram >> 8) & 0xff));
			try self.mark(tag_uni | (gram & 0xff));
		}
		for (self.touched.items) |gram| {
			try self.post(gram);
			self.seen[bucket(gram) >> 6] = 0;
		}
		self.touched.clearRetainingCapacity();
		self.unit = next;
	}

	fn post(self: *Poster, gram: u32) !void {
		const ref = &self.slot_of[bucket(gram)];
		if (ref.* == none) {
			ref.* = @intCast(self.slots.items.len);
			try self.slots.append(self.allocator, .{ .gram = gram });
		}
		const slot = &self.slots.items[ref.*];
		if (slot.count > 0 and slot.last == self.unit) return;
		var scratch: [10]u8 = undefined;
		const bytes = index.encodeVarint(&scratch, self.unit - slot.last);
		for (bytes) |byte| {
			if (slot.used == chunk_data) {
				const fresh: u32 = @intCast(self.chunks.items.len);
				try self.chunks.append(self.allocator, .{ .data = undefined, .next = none });
				if (slot.tail == none) slot.head = fresh else self.chunks.items[slot.tail].next = fresh;
				slot.tail = fresh;
				slot.used = 0;
			}
			self.chunks.items[slot.tail].data[slot.used] = byte;
			slot.used += 1;
		}
		slot.len += @intCast(bytes.len);
		slot.last = self.unit;
		slot.count += 1;
	}

	fn write(self: *Poster, w: *std.Io.Writer, keys: *std.ArrayList(index.Key), base: u64) !u64 {
		std.sort.pdq(Slot, self.slots.items, {}, struct {
			fn less(_: void, a: Slot, b: Slot) bool {
				return a.gram < b.gram;
			}
		}.less);
		var off = base;
		for (self.slots.items) |slot| {
			try keys.append(self.allocator, .{ .gram = slot.gram, .count = slot.count, .off = @intCast(off) });
			off += slot.len;
			var left: usize = slot.len;
			var at = slot.head;
			while (left > 0) : (at = self.chunks.items[at].next) {
				const take = @min(left, chunk_data);
				try w.writeAll(self.chunks.items[at].data[0..take]);
				left -= take;
			}
		}
		return off;
	}
};

const Posters = struct {
	crew: Crew,
	allocator: Allocator,
	posters: [2]Poster,
	feeds: [2]std.ArrayList(u8) = .{ .empty, .empty },
	filling: usize = 0,
	shipped: usize = 0,

	fn job(ctx: *anyopaque, i: usize) anyerror!void {
		const self: *Posters = @ptrCast(@alignCast(ctx));
		try self.posters[i].feed(self.feeds[self.shipped].items);
	}

	fn deinit(self: *Posters) void {
		self.crew.shutdown();
		for (&self.posters) |*poster| poster.deinit();
		for (&self.feeds) |*feed| feed.deinit(self.allocator);
	}

	fn add(self: *Posters, name: []const u8, block: u32) !void {
		var head: [5]u8 = undefined;
		std.mem.writeInt(u32, head[0..4], block, .little);
		head[4] = @intCast(name.len);
		var low: [256]u8 = undefined;
		try self.feeds[self.filling].appendSlice(self.allocator, &head);
		try self.feeds[self.filling].appendSlice(self.allocator, index.fold(&low, name));
	}

	fn ship(self: *Posters) !void {
		try self.crew.wait();
		self.shipped = self.filling;
		self.crew.go();
		self.filling = 1 - self.filling;
		self.feeds[self.filling].clearRetainingCapacity();
	}

	fn finish(self: *Posters) !void {
		try self.ship();
		try self.crew.wait();
		for (&self.posters) |*poster| try poster.flush(0);
	}
};

const Encoder = struct {
	allocator: Allocator,
	w: *std.Io.Writer,
	posters: *Posters,
	starts: std.ArrayList(u32) = .empty,
	names_len: u64 = 0,
	count: u32 = 0,
	prev: [256]u8 = undefined,
	prev_len: usize = 0,
	prev_parent: u32 = 0,

	fn add(self: *Encoder, name: []const u8, parent: u32, dir: bool) !u32 {
		const id = self.count;
		if (id % index.block_size == 0) {
			try self.starts.append(self.allocator, @intCast(self.names_len));
			self.prev_len = 0;
			self.prev_parent = 0;
		}
		const shared = std.mem.indexOfDiff(u8, self.prev[0..self.prev_len], name) orelse name.len;
		var scratch: [10]u8 = undefined;
		const tail = index.encodeVarint(&scratch, index.zigzag(@as(i64, parent) - @as(i64, self.prev_parent)) << 1 | @intFromBool(dir));
		try self.w.writeAll(&.{ @intCast(shared), @intCast(name.len - shared) });
		try self.w.writeAll(name[shared..]);
		try self.w.writeAll(tail);
		self.names_len += 2 + name.len - shared + tail.len;
		@memcpy(self.prev[shared..name.len], name[shared..]);
		self.prev_len = name.len;
		self.prev_parent = parent;
		if (parent != none) try self.posters.add(name, id / index.block_size);
		self.count += 1;
		return id;
	}
};

const Dir = struct {
	path: []u8,
	id: u32,
	depth: u16,
	old: u32 = none,
	parent: u32 = none,
};

const Child = struct {
	key: u64,
	off: u32,
	len: u8,
	dir: bool,
	old: u32 = none,
};

const Listing = struct {
	lister: u8,
	from: u32,
	to: u32,
	mtime: i64 = 0,
	ok: bool = false,
};

const Lister = struct {
	allocator: Allocator,
	index: u8,
	home: []const u8,
	old: ?*const index.Index,
	children: std.ArrayList(Child) = .empty,
	names: std.ArrayList(u8) = .empty,
	path: std.ArrayList(u8) = .empty,

	fn deinit(self: *Lister) void {
		self.children.deinit(self.allocator);
		self.names.deinit(self.allocator);
		self.path.deinit(self.allocator);
	}

	fn run(self: *Lister, dirs: []const Dir, results: []Listing, cursor: *std.atomic.Value(usize)) !void {
		while (true) {
			const at = cursor.fetchAdd(1, .monotonic);
			if (at >= dirs.len) return;
			results[at] = try self.list(dirs[at]);
		}
	}

	fn setPath(self: *Lister, parts: []const []const u8) ![]const u8 {
		self.path.clearRetainingCapacity();
		for (parts) |part| try self.path.appendSlice(self.allocator, part);
		return self.path.items;
	}

	fn list(self: *Lister, dir: Dir) !Listing {
		const from: u32 = @intCast(self.children.items.len);
		var listing: Listing = .{ .lister = self.index, .from = from, .to = from };
		const z: [*:0]const u8 = @ptrCast((try self.setPath(&.{ if (dir.path.len == 0) "/" else dir.path, "\x00" })).ptr);
		listing.mtime = mtimeOf(z);
		if (listing.mtime < 0) return listing;
		const record = if (self.old != null and dir.old != none) self.old.?.dirOf(dir.old) else null;
		if (record != null and record.?.partial == 0 and record.?.mtime == listing.mtime) {
			try self.reuse(record.?);
		} else {
			var entries = Entries.open(z) orelse return listing;
			defer entries.close();
			try self.read(dir, &entries);
		}
		listing.to = @intCast(self.children.items.len);
		listing.ok = true;
		const fresh = self.children.items[from..listing.to];
		if (record == null or (record.?.partial == 0 and record.?.mtime == listing.mtime)) return listing;
		var range = self.old.?.children(record.?.first);
		var buf: [256]u8 = undefined;
		var at: usize = 0;
		for (0..record.?.count) |i| {
			const old = range.next(&buf) orelse break;
			while (at < fresh.len and std.mem.order(u8, self.names.items[fresh[at].off..][0..fresh[at].len], old.name) == .lt) at += 1;
			if (at < fresh.len and old.dir and std.mem.eql(u8, self.names.items[fresh[at].off..][0..fresh[at].len], old.name)) fresh[at].old = record.?.first + @as(u32, @intCast(i));
		}
		return listing;
	}

	fn reuse(self: *Lister, record: index.DirRecord) !void {
		var range = self.old.?.children(record.first);
		var buf: [256]u8 = undefined;
		for (0..record.count) |i| {
			const item = range.next(&buf) orelse return;
			try self.push(item.name, item.dir, if (item.dir) record.first + @as(u32, @intCast(i)) else none);
		}
	}

	fn read(self: *Lister, dir: Dir, entries: *Entries) !void {
		const from = self.children.items.len;
		while (entries.next()) |entry| {
			const name = nameOf(entry);
			if (name.len == 0 or name.len > 255 or skipName(name)) continue;
			if (name[0] == '.' and !(std.mem.eql(u8, name, ".config") and std.mem.eql(u8, dir.path, self.home))) continue;
			if (dir.depth <= 2 and skipPath(try self.setPath(&.{ dir.path, "/", name }))) continue;
			var is_dir = entry.type == linux.DT.DIR;
			if (entry.type == linux.DT.UNKNOWN) {
				var st: linux.Statx = undefined;
				if (linux.errno(linux.statx(entries.fd, @ptrCast(&entry.name), linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) continue;
				is_dir = std.posix.S.ISDIR(st.mode);
			}
			try self.push(name, is_dir, none);
		}
		std.sort.pdq(Child, self.children.items[from..], self.names.items, struct {
			fn less(names: []const u8, a: Child, b: Child) bool {
				if (a.key != b.key) return a.key < b.key;
				return std.mem.lessThan(u8, names[a.off..][0..a.len], names[b.off..][0..b.len]);
			}
		}.less);
	}

	fn push(self: *Lister, name: []const u8, dir: bool, old: u32) !void {
		var prefix: [8]u8 = @splat(0);
		@memcpy(prefix[0..@min(8, name.len)], name[0..@min(8, name.len)]);
		try self.children.append(self.allocator, .{ .key = std.mem.readInt(u64, &prefix, .big), .off = @intCast(self.names.items.len), .len = @intCast(name.len), .dir = dir, .old = old });
		try self.names.appendSlice(self.allocator, name);
	}
};

const Batch = struct {
	listers: []Lister,
	results: std.ArrayList(Listing) = .empty,
	from: usize = 0,
	to: usize = 0,
};

const Pool = struct {
	crew: Crew,
	batches: [2]Batch,
	current: *Batch = undefined,
	dirs: []const Dir = &.{},
	cursor: std.atomic.Value(usize) = .init(0),

	fn job(ctx: *anyopaque, i: usize) anyerror!void {
		const self: *Pool = @ptrCast(@alignCast(ctx));
		try self.current.listers[i].run(self.dirs, self.current.results.items, &self.cursor);
	}

	fn list(self: *Pool, allocator: Allocator, batch: *Batch, dirs: []const Dir, from: usize) !void {
		batch.from = from;
		batch.to = @min(from + batch_dirs, dirs.len);
		try batch.results.resize(allocator, batch.to - from);
		self.cursor.store(0, .monotonic);
		self.current = batch;
		self.dirs = dirs[from..batch.to];
		self.crew.go();
	}
};

const Walker = struct {
	allocator: Allocator,
	encoder: *Encoder,
	pool: *Pool,
	blocked: []const []const u8,
	records: *std.ArrayList(index.DirRecord),
	dir_names: *std.ArrayList(u8),
	exclude: []const u8 = "",
	ancestors: []const Dir = &.{},

	fn walk(self: *Walker, start: Dir) !void {
		var level: std.ArrayList(Dir) = .empty;
		defer freeDirs(self.allocator, &level);
		var head = start;
		head.path = try self.allocator.dupe(u8, start.path);
		try level.append(self.allocator, head);
		defer self.pool.crew.wait() catch {};

		while (level.items.len > 0) {
			var next: std.ArrayList(Dir) = .empty;
			errdefer freeDirs(self.allocator, &next);
			const batches = (level.items.len + batch_dirs - 1) / batch_dirs;
			try self.pool.list(self.allocator, &self.pool.batches[0], level.items, 0);
			for (0..batches) |b| {
				const batch = &self.pool.batches[b % 2];
				try self.pool.crew.wait();
				if (b + 1 < batches) try self.pool.list(self.allocator, &self.pool.batches[(b + 1) % 2], level.items, (b + 1) * batch_dirs);
				for (level.items[batch.from..batch.to], batch.results.items) |*dir, listing| {
					const first = self.encoder.count;
					const whole = try self.emit(dir.*, &batch.listers[listing.lister], listing, &next);
					if (listing.ok) {
						const name = if (dir.parent == none) dir.path else std.fs.path.basename(dir.path);
						try self.records.append(self.allocator, .{ .id = dir.id, .first = first, .count = self.encoder.count - first, .up = dir.parent, .name_off = @intCast(self.dir_names.items.len), .name_len = @intCast(name.len), .partial = @intFromBool(!whole), .mtime = listing.mtime });
						try self.dir_names.appendSlice(self.allocator, name);
					}
					self.allocator.free(dir.path);
					dir.path = &.{};
				}
				for (batch.listers) |*lister| {
					lister.children.clearRetainingCapacity();
					lister.names.clearRetainingCapacity();
				}
				try self.encoder.posters.ship();
			}
			freeDirs(self.allocator, &level);
			level = next;
		}
	}

	fn emit(self: *Walker, dir: Dir, lister: *Lister, listing: Listing, next: *std.ArrayList(Dir)) !bool {
		var whole = true;
		for (lister.children.items[listing.from..listing.to]) |child| {
			const name = lister.names.items[child.off..][0..child.len];
			const path = if (child.dir) try std.mem.concat(self.allocator, u8, &.{ dir.path, "/", name }) else "";
			var keep = false;
			defer if (!keep) self.allocator.free(path);
			if (child.dir and dir.depth <= 2) {
				if (std.mem.eql(u8, path, self.exclude)) {
					whole = false;
					continue;
				}
				if (for (self.ancestors) |ancestor| {
					if (std.mem.eql(u8, path, ancestor.path)) break ancestor;
				} else null) |ancestor| {
					try next.append(self.allocator, .{ .path = @constCast(path), .id = ancestor.id, .depth = dir.depth +| 1, .old = ancestor.old, .parent = dir.id });
					keep = true;
					whole = false;
					continue;
				}
			}
			const id = try self.encoder.add(name, dir.id, child.dir);
			if (!child.dir or contains(self.blocked, path)) continue;
			try next.append(self.allocator, .{ .path = @constCast(path), .id = id, .depth = dir.depth +| 1, .old = child.old, .parent = dir.id });
			keep = true;
		}
		return whole;
	}
};

fn freeDirs(allocator: Allocator, dirs: *std.ArrayList(Dir)) void {
	for (dirs.items) |dir| allocator.free(dir.path);
	dirs.deinit(allocator);
	dirs.* = .empty;
}

pub fn build(io: Io, allocator: Allocator, root: []const u8, home: []const u8, out_path: []const u8, built_ms: i64) !void {
	const root_name = std.mem.trimEnd(u8, root, "/");
	const home_path = std.mem.trimEnd(u8, home, "/");
	if (root_name.len > 255) return error.RootTooLong;

	const scope = std.hash.Wyhash.hash(index.version, root_name) ^ std.hash.Wyhash.hash(1, home_path);
	var previous: ?index.Index = index.load(io, out_path) catch null;
	defer if (previous) |*loaded| loaded.deinit();
	if (previous != null and previous.?.scope != scope) {
		previous.?.deinit();
		previous = null;
	}
	const old: ?*const index.Index = if (previous) |*loaded| loaded else null;
	if (old != null and unchanged(old.?)) {
		var file = try std.Io.Dir.cwd().openFile(io, out_path, .{ .mode = .read_write });
		defer file.close(io);
		const stamp = std.mem.asBytes(&built_ms);
		if (linux.errno(linux.pwrite(file.handle, stamp, stamp.len, @offsetOf(index.Header, "built_ms"))) != .SUCCESS) return error.WriteFailed;
		return;
	}

	const temp = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}", .{ std.fs.path.dirname(out_path) orelse ".", std.fs.path.basename(out_path), linux.getpid() });
	defer allocator.free(temp);
	if (std.fs.path.dirname(out_path)) |parent_dir| try std.Io.Dir.cwd().createDirPath(io, parent_dir);
	var file = try std.Io.Dir.cwd().createFile(io, temp, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
	var closed = false;
	defer if (!closed) file.close(io);
	errdefer std.Io.Dir.cwd().deleteFile(io, temp) catch {};

	var buffer: [64 * 1024]u8 = undefined;
	var writer = file.writer(io, &buffer);
	const w = &writer.interface;
	var header: index.Header = .{ .built_ms = built_ms, .names_at = @sizeOf(index.Header), .scope = scope };
	try w.writeAll(std.mem.asBytes(&header));

	const posters = try allocator.create(Posters);
	defer allocator.destroy(posters);
	posters.* = .{ .crew = .{ .io = io, .job = Posters.job, .size = 2 }, .allocator = allocator, .posters = .{
		.{ .allocator = allocator, .tri = true },
		.{ .allocator = allocator, .tri = false },
	} };
	defer posters.deinit();
	for (&posters.posters) |*poster| {
		poster.slot_of = try allocator.alloc(u32, buckets);
		@memset(poster.slot_of, none);
	}
	posters.crew.spawn(posters);

	const threads = @min(std.Thread.getCpuCount() catch 1, max_threads);
	var listers: [2][max_threads]Lister = undefined;
	var pool: Pool = .{ .crew = .{ .io = io, .job = Pool.job, .size = threads }, .batches = undefined };
	for (&listers, &pool.batches) |*set, *batch| {
		for (set[0..threads], 0..) |*lister, i| lister.* = .{ .allocator = allocator, .index = @intCast(i), .home = home_path, .old = old };
		batch.* = .{ .listers = set[0..threads] };
	}
	defer for (&listers, &pool.batches) |*set, *batch| {
		for (set[0..threads]) |*lister| lister.deinit();
		batch.results.deinit(allocator);
	};
	pool.crew.spawn(&pool);
	defer pool.crew.shutdown();

	var encoder: Encoder = .{ .allocator = allocator, .w = w, .posters = posters };
	defer encoder.starts.deinit(allocator);
	_ = try encoder.add(root_name, none, true);

	var blocked = try blockedMounts(io, allocator, root_name, home_path);
	defer freePaths(allocator, &blocked);
	var ancestors: std.ArrayList(Dir) = .empty;
	defer freeDirs(allocator, &ancestors);
	var records: std.ArrayList(index.DirRecord) = .empty;
	defer records.deinit(allocator);
	var dir_names: std.ArrayList(u8) = .empty;
	defer dir_names.deinit(allocator);
	var walker: Walker = .{ .allocator = allocator, .encoder = &encoder, .pool = &pool, .blocked = blocked.items, .records = &records, .dir_names = &dir_names };

	if (home_path.len > root_name.len and within(home_path, root_name) and !hidden(home_path[root_name.len..])) {
		var parts = std.mem.tokenizeScalar(u8, home_path[root_name.len..], '/');
		while (parts.next()) |part| {
			const parent = if (ancestors.items.len == 0) 0 else ancestors.items[ancestors.items.len - 1].id;
			const end = @intFromPtr(part.ptr) - @intFromPtr(home_path.ptr) + part.len;
			const was = if (old) |o| o.find(home_path[root_name.len..end]) else none;
			try ancestors.append(allocator, .{ .path = try allocator.dupe(u8, home_path[0..end]), .id = try encoder.add(part, parent, true), .depth = 0, .old = was, .parent = parent });
		}
		const top = ancestors.pop().?;
		defer allocator.free(top.path);
		try walker.walk(.{ .path = top.path, .id = top.id, .depth = 3, .old = top.old, .parent = top.parent });
		walker.exclude = home_path;
		walker.ancestors = ancestors.items;
	}
	try walker.walk(.{ .path = @constCast(root_name), .id = 0, .depth = 0, .old = if (old != null) 0 else none });
	try posters.finish();
	try encoder.starts.append(allocator, @intCast(encoder.names_len));

	var keys: std.ArrayList(index.Key) = .empty;
	defer keys.deinit(allocator);
	header.count = encoder.count;
	header.blocks = @intCast(encoder.starts.items.len - 1);
	header.names_len = encoder.names_len;
	header.post_at = header.names_at + header.names_len;
	header.post_len = try posters.posters[1].write(w, &keys, try posters.posters[0].write(w, &keys, 0));
	header.keys = @intCast(keys.items.len);
	const pad = (4 - (header.post_at + header.post_len) % 4) % 4;
	try w.splatByteAll(0, pad);
	header.starts_at = header.post_at + header.post_len + pad;
	header.keys_at = header.starts_at + encoder.starts.items.len * 4;
	try w.writeAll(std.mem.sliceAsBytes(encoder.starts.items));
	try w.writeAll(std.mem.sliceAsBytes(keys.items));
	std.sort.pdq(index.DirRecord, records.items, {}, struct {
		fn less(_: void, a: index.DirRecord, b: index.DirRecord) bool {
			return a.id < b.id;
		}
	}.less);
	const end = header.keys_at + keys.items.len * @sizeOf(index.Key);
	try w.splatByteAll(0, (8 - end % 8) % 8);
	header.dirs_at = end + (8 - end % 8) % 8;
	header.dirs = records.items.len;
	for (records.items) |*record| {
		if (record.up == none) continue;
		record.up = @intCast(std.sort.lowerBound(index.DirRecord, records.items, record.up, struct {
			fn order(target: u32, item: index.DirRecord) std.math.Order {
				return std.math.order(target, item.id);
			}
		}.order));
	}
	try w.writeAll(std.mem.sliceAsBytes(records.items));
	header.dir_names_at = header.dirs_at + records.items.len * @sizeOf(index.DirRecord);
	header.dir_names_len = dir_names.items.len;
	try w.writeAll(dir_names.items);
	try w.flush();

	if (linux.errno(linux.pwrite(file.handle, std.mem.asBytes(&header), @sizeOf(index.Header), 0)) != .SUCCESS) return error.WriteFailed;
	file.close(io);
	closed = true;
	try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), out_path, io);
}

fn unchanged(old: *const index.Index) bool {
	var buffer: [std.fs.max_path_bytes]u8 = undefined;
	var z: [std.fs.max_path_bytes + 1]u8 = undefined;
	for (old.dirs, 0..) |record, at| {
		const path = std.fmt.bufPrintSentinel(&z, "{s}", .{old.dirPath(at, &buffer)}, 0) catch return false;
		if (mtimeOf(path) != record.mtime) return false;
	}
	return true;
}

pub fn changes(allocator: Allocator, old: *const index.Index, home: []const u8, sink: anytype) !usize {
	const stale = try allocator.alloc(bool, old.dirs.len);
	defer allocator.free(stale);
	const threads = @min(std.Thread.getCpuCount() catch 1, max_threads);
	var workers: [max_threads]?std.Thread = @splat(null);
	for (workers[0..threads], 0..) |*worker, t| {
		const from = old.dirs.len * t / threads;
		const to = old.dirs.len * (t + 1) / threads;
		worker.* = std.Thread.spawn(.{}, check, .{ old, stale, from, to }) catch blk: {
			check(old, stale, from, to);
			break :blk null;
		};
	}
	for (workers[0..threads]) |worker| if (worker) |thread| thread.join();

	var buffer: [std.fs.max_path_bytes]u8 = undefined;
	var z: [std.fs.max_path_bytes + 1]u8 = undefined;
	var changed: usize = 0;
	for (old.dirs, stale, 0..) |record, dirty, at| {
		if (!dirty) continue;
		changed += 1;
		const path = std.fmt.bufPrintSentinel(&z, "{s}", .{old.dirPath(at, &buffer)}, 0) catch continue;
		var arena = std.heap.ArenaAllocator.init(allocator);
		defer arena.deinit();
		var known: std.StringHashMapUnmanaged(void) = .empty;
		var range = old.children(record.first);
		var name_buf: [256]u8 = undefined;
		for (0..record.count) |_| try known.put(arena.allocator(), try arena.allocator().dupe(u8, (range.next(&name_buf) orelse break).name), {});
		try added(path, &known, home, sink, 0);
	}
	return changed;
}

fn check(old: *const index.Index, stale: []bool, from: usize, to: usize) void {
	var buffer: [std.fs.max_path_bytes]u8 = undefined;
	var z: [std.fs.max_path_bytes + 1]u8 = undefined;
	var up: u32 = none;
	var prefix: usize = 0;
	for (from..to) |at| {
		const record = old.dirs[at];
		const stored = old.dir_names[record.name_off..][0..record.name_len];
		const name = if (record.up == none and stored.len == 0) "/" else stored;
		if (record.up == none or record.up != up or prefix + name.len + 2 > z.len) {
			const parent = if (record.up == none) "" else std.mem.trimEnd(u8, old.dirPath(record.up, &buffer), "/");
			prefix = parent.len;
			@memcpy(z[0..prefix], parent);
			up = record.up;
		}
		var len = prefix;
		if (record.up != none) {
			z[len] = '/';
			len += 1;
		}
		@memcpy(z[len..][0..name.len], name);
		len += name.len;
		z[len] = 0;
		stale[at] = mtimeOf(z[0..len :0]) != record.mtime;
	}
}

fn added(path: [:0]const u8, known: ?*const std.StringHashMapUnmanaged(void), home: []const u8, sink: anytype, depth: u8) !void {
	if (depth > 24) return;
	var entries = Entries.open(path) orelse return;
	defer entries.close();
	const dev = devOf(path);
	var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
	while (entries.next()) |entry| {
		const name = nameOf(entry);
		if (name.len == 0 or name.len > 255 or skipName(name)) continue;
		if (name[0] == '.' and !(std.mem.eql(u8, name, ".config") and std.mem.eql(u8, path, home))) continue;
		if (known) |names| if (names.contains(name)) continue;
		const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ if (std.mem.eql(u8, path, "/")) "" else path, name }, 0) catch continue;
		if (skipPath(full) or (guard.hasPrefix(home, full) and full.len < home.len)) continue;
		if (!try sink.found(full)) return error.Full;
		if (entry.type == linux.DT.DIR and devOf(full) == dev) try added(full, null, home, sink, depth + 1);
	}
}

fn devOf(path: [*:0]const u8) u64 {
	var st: linux.Statx = undefined;
	if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) return 0;
	return @as(u64, st.dev_major) << 32 | st.dev_minor;
}

pub fn mtimeOf(path: [*:0]const u8) i64 {
	var st: linux.Statx = undefined;
	if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .MTIME = true }, &st)) != .SUCCESS) return -1;
	return st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
}

pub fn command(io: Io, args: []const []const u8) !void {
	if (args.len < 5) return error.Usage;
	_ = linux.syscall3(.setpriority, 0, 0, 19);
	try build(io, std.heap.smp_allocator, args[2], args[3], args[4], std.Io.Clock.real.now(io).toMilliseconds());
}

const Mount = struct {
	point: []const u8,
	source: []const u8,
};

fn blockedMounts(io: Io, allocator: Allocator, root: []const u8, home: []const u8) !std.ArrayList([]const u8) {
	var blocked: std.ArrayList([]const u8) = .empty;
	errdefer freePaths(allocator, &blocked);
	const body = proc.readFile(io, allocator, "/proc/self/mountinfo") catch return blocked;
	defer allocator.free(body);

	var mounts: std.ArrayList(Mount) = .empty;
	defer {
		for (mounts.items) |mount| allocator.free(mount.point);
		mounts.deinit(allocator);
	}
	var lines = std.mem.splitScalar(u8, body, '\n');
	while (lines.next()) |line| {
		const dash = std.mem.indexOf(u8, line, " - ") orelse continue;
		var head = std.mem.tokenizeScalar(u8, line[0..dash], ' ');
		for (0..4) |_| _ = head.next();
		const point = head.next() orelse continue;
		var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
		_ = tail.next();
		const source = tail.next() orelse continue;
		try mounts.append(allocator, .{ .point = try guard.unescape(allocator, point), .source = source });
	}

	const keep_root = sourceOf(mounts.items, root);
	const keep_home = sourceOf(mounts.items, home);
	for (mounts.items) |mount| {
		if (std.mem.eql(u8, mount.source, keep_root) or std.mem.eql(u8, mount.source, keep_home)) continue;
		if (!within(mount.point, root) or std.mem.eql(u8, mount.point, root) or contains(blocked.items, mount.point)) continue;
		try blocked.append(allocator, try allocator.dupe(u8, mount.point));
	}
	return blocked;
}

fn contains(paths: []const []const u8, path: []const u8) bool {
	for (paths) |known| if (std.mem.eql(u8, known, path)) return true;
	return false;
}

fn freePaths(allocator: Allocator, paths: *std.ArrayList([]const u8)) void {
	for (paths.items) |path| allocator.free(path);
	paths.deinit(allocator);
}

fn sourceOf(mounts: []const Mount, path: []const u8) []const u8 {
	var best: ?Mount = null;
	for (mounts) |mount| {
		if (within(path, mount.point) and (best == null or mount.point.len >= best.?.point.len)) best = mount;
	}
	return if (best) |mount| mount.source else "";
}

fn within(path: []const u8, root: []const u8) bool {
	if (root.len == 0 or std.mem.eql(u8, root, "/")) return path.len > 0 and path[0] == '/';
	return guard.hasPrefix(path, root);
}

fn hidden(rel: []const u8) bool {
	var parts = std.mem.tokenizeScalar(u8, rel, '/');
	while (parts.next()) |part| if (part[0] == '.') return true;
	return false;
}

fn touch(io: Io, root: []const u8, sub: []const u8, dir: bool) !void {
	var buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, sub });
	if (dir) return std.Io.Dir.cwd().createDirPath(io, path);
	var file = try std.Io.Dir.cwd().createFile(io, path, .{});
	file.close(io);
}

test "file index finds names by substring, ranks shallow first, skips hidden, keeps dirs and paths" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);

	for ([_][]const u8{ "Docs/deep/more", "node_modules/pkg", "Photos", ".secret", "many" }) |sub| try touch(io, root, sub, true);
	for ([_][]const u8{ "Report.pdf", "Docs/deep/more/old-report.txt", "node_modules/pkg/report.js", "Photos/cat.png", ".secret/report.key", ".hidden-report" }) |sub| try touch(io, root, sub, false);
	var name_buf: [32]u8 = undefined;
	for (0..300) |i| try touch(io, root, try std.fmt.bufPrint(&name_buf, "many/file-{d}.txt", .{i}), false);

	const index_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{root});
	defer allocator.free(index_path);
	defer std.Io.Dir.cwd().deleteFile(io, index_path) catch {};
	try build(io, allocator, root, root, index_path, 42);
	var built = try index.load(io, index_path);
	defer built.deinit();
	try std.testing.expectEqual(@as(i64, 42), built.built_ms);

	var hits: [400]u32 = undefined;
	var buffer: [4096]u8 = undefined;
	var buf: [256]u8 = undefined;
	try std.testing.expectEqual(@as(usize, 2), built.search("report", &hits));
	try std.testing.expectEqualStrings("Report.pdf", built.item(hits[0], &buf).name);
	try std.testing.expectEqualStrings("old-report.txt", built.item(hits[1], &buf).name);
	const full = try std.fmt.allocPrint(allocator, "{s}/Docs/deep/more/old-report.txt", .{root});
	defer allocator.free(full);
	try std.testing.expectEqualStrings(full, built.path(&buffer, hits[1]));

	try std.testing.expectEqual(@as(usize, 1), built.search("ca", &hits));
	try std.testing.expectEqualStrings("cat.png", built.item(hits[0], &buf).name);
	try std.testing.expectEqual(@as(usize, 1), built.search("g", &hits));
	try std.testing.expectEqual(@as(usize, 1), built.search("photos", &hits));
	try std.testing.expect(built.item(hits[0], &buf).dir);
	try std.testing.expectEqual(@as(usize, 0), built.search("zzzq", &hits));
	try std.testing.expectEqual(@as(usize, 0), built.search("secret", &hits));
	try std.testing.expectEqual(@as(usize, 300), built.search("file-", &hits));
	for (hits[0..300]) |id| try std.testing.expect(std.mem.endsWith(u8, built.path(&buffer, id), ".txt"));
	try std.testing.expectEqual(@as(usize, 1), built.search("file-277.t", &hits));
	try std.testing.expectEqualStrings("file-277.txt", built.item(hits[0], &buf).name);

	const docs = try std.fmt.allocPrint(allocator, "{s}/Docs", .{root});
	defer allocator.free(docs);
	try build(io, allocator, root, docs, index_path, 43);
	var homed = try index.load(io, index_path);
	defer homed.deinit();
	try std.testing.expectEqual(built.count, homed.count);
	try std.testing.expectEqual(@as(usize, 1), homed.search("docs", &hits));
	try std.testing.expectEqual(@as(usize, 2), homed.search("report", &hits));
	try std.testing.expectEqualStrings(full, homed.path(&buffer, hits[0]));
}

test "mounts on another device are blocked, the root and home devices are kept" {
	const mounts = [_]Mount{
		.{ .point = "/", .source = "/dev/sda2" },
		.{ .point = "/home", .source = "/dev/sda2" },
		.{ .point = "/mnt/usb", .source = "/dev/sdb1" },
		.{ .point = "/home/me/nas", .source = "nas:/share" },
	};
	try std.testing.expectEqualStrings("/dev/sda2", sourceOf(&mounts, "/home/me"));
	try std.testing.expectEqualStrings("/dev/sdb1", sourceOf(&mounts, "/mnt/usb/photos"));
	try std.testing.expect(within("/mnt", "/"));
	try std.testing.expect(within("/home/me", "/home"));
	try std.testing.expect(!within("/homes", "/home"));
}

test "a rebuild reuses unchanged folders and picks up changed ones" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);
	const index_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{root});
	defer allocator.free(index_path);
	defer std.Io.Dir.cwd().deleteFile(io, index_path) catch {};

	for ([_][]const u8{ "a/b/c", "z" }) |sub| try touch(io, root, sub, true);
	for ([_][]const u8{ "a/old.txt", "a/b/keep.txt", "a/b/c/deep.txt", "z/zed.txt" }) |sub| try touch(io, root, sub, false);
	try build(io, allocator, root, root, index_path, 1);
	try build(io, allocator, root, root, index_path, 2);
	var hits: [8]u32 = undefined;
	var buffer: [4096]u8 = undefined;
	{
		var same = try index.load(io, index_path);
		defer same.deinit();
		try std.testing.expectEqual(@as(usize, 1), same.search("deep", &hits));
		try std.testing.expect(std.mem.endsWith(u8, same.path(&buffer, hits[0]), "/a/b/c/deep.txt"));
		try std.testing.expect(same.dirs.len >= 4);
	}

	try touch(io, root, "a/b/new-file.txt", false);
	try touch(io, root, "z/fresh-dir", true);
	const gone = try std.fmt.allocPrint(allocator, "{s}/a/old.txt", .{root});
	defer allocator.free(gone);
	try std.Io.Dir.cwd().deleteFile(io, gone);
	try build(io, allocator, root, root, index_path, 3);

	var changed = try index.load(io, index_path);
	defer changed.deinit();
	try std.testing.expectEqual(@as(usize, 1), changed.search("new-file", &hits));
	try std.testing.expect(std.mem.endsWith(u8, changed.path(&buffer, hits[0]), "/a/b/new-file.txt"));
	try std.testing.expectEqual(@as(usize, 0), changed.search("old.txt", &hits));
	try std.testing.expectEqual(@as(usize, 1), changed.search("fresh-dir", &hits));
	try std.testing.expectEqual(@as(usize, 1), changed.search("deep", &hits));
	try std.testing.expect(std.mem.endsWith(u8, changed.path(&buffer, hits[0]), "/a/b/c/deep.txt"));
	try std.testing.expectEqual(@as(usize, 1), changed.search("zed", &hits));
}

const Collect = struct {
	allocator: Allocator,
	paths: std.ArrayList([]u8) = .empty,

	pub fn found(self: *Collect, path: []const u8) !bool {
		try self.paths.append(self.allocator, try self.allocator.dupe(u8, path));
		return true;
	}

	fn has(self: *const Collect, suffix: []const u8) bool {
		for (self.paths.items) |path| if (std.mem.endsWith(u8, path, suffix)) return true;
		return false;
	}
};

test "the change scan reports only what the index does not have" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);
	const index_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{root});
	defer allocator.free(index_path);
	defer std.Io.Dir.cwd().deleteFile(io, index_path) catch {};

	for ([_][]const u8{ "a/b", "z" }) |sub| try touch(io, root, sub, true);
	for ([_][]const u8{ "a/one.txt", "a/b/two.txt" }) |sub| try touch(io, root, sub, false);
	try build(io, allocator, root, root, index_path, 1);
	var built = try index.load(io, index_path);
	defer built.deinit();

	var none_yet: Collect = .{ .allocator = allocator };
	defer none_yet.paths.deinit(allocator);
	try std.testing.expectEqual(@as(usize, 0), try changes(allocator, &built, root, &none_yet));
	try std.testing.expectEqual(@as(usize, 0), none_yet.paths.items.len);

	try touch(io, root, "a/b/three.txt", false);
	try touch(io, root, "z/fresh/inner", true);
	try touch(io, root, "z/fresh/inner/leaf.txt", false);
	try touch(io, root, "z/.hidden-file", false);
	var seen: Collect = .{ .allocator = allocator };
	defer {
		for (seen.paths.items) |path| allocator.free(path);
		seen.paths.deinit(allocator);
	}
	try std.testing.expectEqual(@as(usize, 2), try changes(allocator, &built, root, &seen));
	try std.testing.expectEqual(@as(usize, 4), seen.paths.items.len);
	for ([_][]const u8{ "/a/b/three.txt", "/z/fresh", "/z/fresh/inner", "/z/fresh/inner/leaf.txt" }) |suffix| try std.testing.expect(seen.has(suffix));
}
