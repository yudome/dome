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
};

const Child = struct {
	key: u64,
	off: u32,
	len: u8,
	dir: bool,
};

const Listing = struct {
	lister: u8,
	from: u32,
	to: u32,
};

const Lister = struct {
	allocator: Allocator,
	index: u8,
	home: []const u8,
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
		_ = try self.setPath(&.{ if (dir.path.len == 0) "/" else dir.path, "\x00" });
		var entries = Entries.open(@ptrCast(self.path.items.ptr)) orelse return .{ .lister = self.index, .from = from, .to = from };
		defer entries.close();

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
			var prefix: [8]u8 = @splat(0);
			@memcpy(prefix[0..@min(8, name.len)], name[0..@min(8, name.len)]);
			try self.children.append(self.allocator, .{ .key = std.mem.readInt(u64, &prefix, .big), .off = @intCast(self.names.items.len), .len = @intCast(name.len), .dir = is_dir });
			try self.names.appendSlice(self.allocator, name);
		}

		const to: u32 = @intCast(self.children.items.len);
		std.sort.pdq(Child, self.children.items[from..to], self.names.items, struct {
			fn less(names: []const u8, a: Child, b: Child) bool {
				if (a.key != b.key) return a.key < b.key;
				return std.mem.lessThan(u8, names[a.off..][0..a.len], names[b.off..][0..b.len]);
			}
		}.less);
		return .{ .lister = self.index, .from = from, .to = to };
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
	exclude: []const u8 = "",
	ancestors: []const Dir = &.{},

	fn walk(self: *Walker, start: Dir) !void {
		var level: std.ArrayList(Dir) = .empty;
		defer freeDirs(self.allocator, &level);
		try level.append(self.allocator, .{ .path = try self.allocator.dupe(u8, start.path), .id = start.id, .depth = start.depth });
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
					try self.emit(dir.*, &batch.listers[listing.lister], listing, &next);
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

	fn emit(self: *Walker, dir: Dir, lister: *Lister, listing: Listing, next: *std.ArrayList(Dir)) !void {
		for (lister.children.items[listing.from..listing.to]) |child| {
			const name = lister.names.items[child.off..][0..child.len];
			const path = if (child.dir) try std.mem.concat(self.allocator, u8, &.{ dir.path, "/", name }) else "";
			var keep = false;
			defer if (!keep) self.allocator.free(path);
			if (child.dir and dir.depth <= 2) {
				if (std.mem.eql(u8, path, self.exclude)) continue;
				if (for (self.ancestors) |ancestor| {
					if (std.mem.eql(u8, path, ancestor.path)) break ancestor;
				} else null) |ancestor| {
					try next.append(self.allocator, .{ .path = @constCast(path), .id = ancestor.id, .depth = dir.depth +| 1 });
					keep = true;
					continue;
				}
			}
			const id = try self.encoder.add(name, dir.id, child.dir);
			if (!child.dir or contains(self.blocked, path)) continue;
			try next.append(self.allocator, .{ .path = @constCast(path), .id = id, .depth = dir.depth +| 1 });
			keep = true;
		}
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
	var header: index.Header = .{ .built_ms = built_ms, .names_at = @sizeOf(index.Header) };
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
		for (set[0..threads], 0..) |*lister, i| lister.* = .{ .allocator = allocator, .index = @intCast(i), .home = home_path };
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
	var walker: Walker = .{ .allocator = allocator, .encoder = &encoder, .pool = &pool, .blocked = blocked.items };

	if (home_path.len > root_name.len and within(home_path, root_name) and !hidden(home_path[root_name.len..])) {
		var parts = std.mem.tokenizeScalar(u8, home_path[root_name.len..], '/');
		while (parts.next()) |part| {
			const parent = if (ancestors.items.len == 0) 0 else ancestors.items[ancestors.items.len - 1].id;
			const end = @intFromPtr(part.ptr) - @intFromPtr(home_path.ptr) + part.len;
			try ancestors.append(allocator, .{ .path = try allocator.dupe(u8, home_path[0..end]), .id = try encoder.add(part, parent, true), .depth = 0 });
		}
		const top = ancestors.pop().?;
		defer allocator.free(top.path);
		try walker.walk(.{ .path = top.path, .id = top.id, .depth = 3 });
		walker.exclude = home_path;
		walker.ancestors = ancestors.items;
	}
	try walker.walk(.{ .path = @constCast(root_name), .id = 0, .depth = 0 });
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
	try w.flush();

	if (linux.errno(linux.pwrite(file.handle, std.mem.asBytes(&header), @sizeOf(index.Header), 0)) != .SUCCESS) return error.WriteFailed;
	file.close(io);
	closed = true;
	try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), out_path, io);
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
