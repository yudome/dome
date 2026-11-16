const std = @import("std");
const linux = std.os.linux;
const guardmod = @import("disk/guard.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const magic = "YUDFILE\x00";
pub const version: u32 = 3;
const dir_bit: u32 = 1 << 31;
const none: u32 = dir_bit - 1;
const block_size = 64;
const max_lists = 8;
const max_threads = 8;
const thread_shift = 27;
const local_mask: u32 = (1 << thread_shift) - 1;
const tag_bi: u32 = 1 << 24;
const tag_uni: u32 = 2 << 24;

const skipped_paths = [_][]const u8{ "/tmp", "/var/tmp", "/var/cache", "/var/log", "/lost+found" };
const skipped_names = [_][]const u8{ "node_modules", "__pycache__", "zig-out" };

const Header = extern struct {
	magic: [8]u8 = magic.*,
	version: u32 = version,
	count: u32 = 0,
	blocks: u32 = 0,
	keys: u32 = 0,
	root: u32 = 0,
	pad: u32 = 0,
	built_ms: i64 = 0,
	names_len: u64 = 0,
	post_len: u64 = 0,
};

const Key = extern struct {
	gram: u32,
	count: u32,
	off: u32,
};

pub const Item = struct {
	name: []const u8,
	parent: u32,
	dir: bool,
};

const Cursor = struct {
	bytes: []const u8,
	at: usize = 0,
	parent: u32 = 0,

	fn next(self: *Cursor, buf: *[256]u8) ?Item {
		if (self.at >= self.bytes.len) return null;
		const shared: usize = self.bytes[self.at];
		const rest: usize = self.bytes[self.at + 1];
		@memcpy(buf[shared .. shared + rest], self.bytes[self.at + 2 ..][0..rest]);
		self.at += 2 + rest;
		const packed_parent = readVarint(self.bytes, &self.at);
		self.parent = @intCast(@as(i64, self.parent) + unzigzag(packed_parent >> 1));
		return .{ .name = buf[0 .. shared + rest], .parent = self.parent, .dir = packed_parent & 1 != 0 };
	}
};

const Postings = struct {
	bytes: []const u8,
	at: usize,
	left: u32,
	block: ?u32 = null,

	fn next(self: *Postings) ?u32 {
		if (self.left == 0) return null;
		self.left -= 1;
		self.block = (self.block orelse 0) + @as(u32, @intCast(readVarint(self.bytes, &self.at)));
		return self.block;
	}

	fn seek(self: *Postings, target: u32) ?u32 {
		if (self.block) |block| if (block >= target) return block;
		while (self.next()) |block| if (block >= target) return block;
		return null;
	}
};

pub const Index = struct {
	mapped: []align(std.heap.page_size_min) const u8,
	starts: []const u32,
	keys: []const Key,
	names: []const u8,
	post: []const u8,
	count: u32,
	root: u32,
	built_ms: i64,

	pub fn deinit(self: *Index) void {
		std.posix.munmap(self.mapped);
	}

	fn cursor(self: *const Index, block: u32) Cursor {
		return .{ .bytes = self.names[self.starts[block]..self.starts[block + 1]] };
	}

	pub fn item(self: *const Index, id: u32, buf: *[256]u8) Item {
		var walk = self.cursor(id / block_size);
		var at = id - id % block_size;
		while (walk.next(buf)) |entry| : (at += 1) {
			if (at == id) return entry;
		}
		return .{ .name = "", .parent = none, .dir = false };
	}

	pub fn path(self: *const Index, buffer: []u8, id: u32) []const u8 {
		var buf: [256]u8 = undefined;
		var end = buffer.len;
		var at = id;
		while (true) {
			const entry = self.item(at, &buf);
			const slash: usize = if (entry.parent == none) 0 else 1;
			if (end < entry.name.len + slash) return "";
			end -= entry.name.len;
			@memcpy(buffer[end .. end + entry.name.len], entry.name);
			if (entry.parent == none) break;
			end -= 1;
			buffer[end] = '/';
			at = entry.parent;
		}
		if (end == buffer.len) return "/";
		return buffer[end..];
	}

	pub fn search(self: *const Index, needle: []const u8, out: []u32) usize {
		if (needle.len == 0 or out.len == 0) return 0;
		var lists: [max_lists]Postings = undefined;
		const used = self.gather(needle, &lists);
		if (used == 0) return 0;

		var buf: [256]u8 = undefined;
		var found: usize = 0;
		next_block: while (lists[0].next()) |first| {
			var block = first;
			agree: while (true) {
				for (lists[1..used]) |*list| {
					const at = list.seek(block) orelse return found;
					if (at == block) continue;
					block = lists[0].seek(at) orelse return found;
					continue :agree;
				}
				break;
			}

			var walk = self.cursor(block);
			var id = block * block_size;
			while (walk.next(&buf)) |entry| : (id += 1) {
				if (id == self.root or std.ascii.findIgnoreCase(entry.name, needle) == null) continue;
				out[found] = id;
				found += 1;
				if (found == out.len) return found;
			}
			continue :next_block;
		}
		return found;
	}

	fn gather(self: *const Index, needle: []const u8, lists: *[max_lists]Postings) usize {
		var grams: [max_lists]u32 = undefined;
		var keys: [max_lists]Key = undefined;
		var used: usize = 0;

		if (needle.len == 1) {
			grams[0] = tag_uni | lower(needle[0]);
			used = 1;
		} else if (needle.len == 2) {
			grams[0] = tag_bi | lower(needle[0]) << 8 | lower(needle[1]);
			used = 1;
		}

		var i: usize = 0;
		while (needle.len >= 3 and i + 3 <= needle.len) : (i += 1) {
			const gram = triOf(needle[i..][0..3]);
			if (std.mem.indexOfScalar(u32, grams[0..used], gram) != null) continue;
			const key = self.lookup(gram) orelse return 0;
			if (used < max_lists) {
				grams[used] = gram;
				keys[used] = key;
				used += 1;
				continue;
			}
			var worst: usize = 0;
			for (keys[0..used], 0..) |k, at| if (k.count > keys[worst].count) {
				worst = at;
			};
			if (key.count < keys[worst].count) {
				grams[worst] = gram;
				keys[worst] = key;
			}
		}

		if (needle.len < 3) keys[0] = self.lookup(grams[0]) orelse return 0;
		std.mem.sort(Key, keys[0..used], {}, struct {
			fn less(_: void, a: Key, b: Key) bool {
				return a.count < b.count;
			}
		}.less);
		for (keys[0..used], lists[0..used]) |key, *list| list.* = .{ .bytes = self.post, .at = key.off, .left = key.count };
		return used;
	}

	fn lookup(self: *const Index, gram: u32) ?Key {
		var lo: usize = 0;
		var hi: usize = self.keys.len;
		while (lo < hi) {
			const mid = (lo + hi) / 2;
			if (self.keys[mid].gram == gram) return self.keys[mid];
			if (self.keys[mid].gram < gram) lo = mid + 1 else hi = mid;
		}
		return null;
	}
};

pub fn load(io: Io, file_path: []const u8) !Index {
	var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
	defer file.close(io);

	const stat = try file.stat(io);
	if (stat.size < @sizeOf(Header)) return error.BadIndex;

	const mapped = try std.posix.mmap(null, @intCast(stat.size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
	errdefer std.posix.munmap(mapped);

	const header: *const Header = @ptrCast(@alignCast(mapped.ptr));
	if (!std.mem.eql(u8, &header.magic, magic) or header.version != version) return error.BadIndex;

	const starts_at: usize = @sizeOf(Header);
	const keys_at = starts_at + (@as(usize, header.blocks) + 1) * 4;
	const names_at = keys_at + @as(usize, header.keys) * @sizeOf(Key);
	const post_at = names_at + header.names_len;
	if (post_at + header.post_len != mapped.len) return error.BadIndex;

	return .{
		.mapped = mapped,
		.starts = @as([*]const u32, @ptrCast(@alignCast(mapped.ptr + starts_at)))[0 .. header.blocks + 1],
		.keys = @as([*]const Key, @ptrCast(@alignCast(mapped.ptr + keys_at)))[0..header.keys],
		.names = mapped[names_at..post_at],
		.post = mapped[post_at..],
		.count = header.count,
		.root = header.root,
		.built_ms = header.built_ms,
	};
}

const Job = struct {
	path: []u8,
	parent: u32,
	depth: u16,
};

const Queue = struct {
	mutex: std.Io.Mutex = .init,
	jobs: std.ArrayList(Job) = .empty,
	active: usize = 0,
	failed: bool = false,
};

const Walk = struct {
	allocator: Allocator,
	queue: *Queue,
	thread: u32,
	home: []const u8,
	parents: std.ArrayList(u32) = .empty,
	offs: std.ArrayList(u32) = .empty,
	ranks: std.ArrayList(u16) = .empty,
	names: std.ArrayList(u8) = .empty,
	path: std.ArrayList(u8) = .empty,

	fn deinit(self: *Walk) void {
		self.parents.deinit(self.allocator);
		self.offs.deinit(self.allocator);
		self.ranks.deinit(self.allocator);
		self.names.deinit(self.allocator);
		self.path.deinit(self.allocator);
	}

	fn add(self: *Walk, parent: u32, entry_name: []const u8, dir: bool, rank: u16) !u32 {
		const local: u32 = @intCast(self.parents.items.len);
		if (local > local_mask) return error.TooManyEntries;
		try self.parents.append(self.allocator, parent | (if (dir) dir_bit else 0));
		try self.offs.append(self.allocator, @intCast(self.names.items.len));
		try self.ranks.append(self.allocator, rank);
		try self.names.appendSlice(self.allocator, entry_name);
		return self.thread << thread_shift | local;
	}

	fn nameOf(self: *const Walk, id: u32) []const u8 {
		const to = if (id + 1 < self.offs.items.len) self.offs.items[id + 1] else @as(u32, @intCast(self.names.items.len));
		return self.names.items[self.offs.items[id]..to];
	}

	fn push(self: *Walk, job: Job) void {
		self.queue.mutex.lockUncancelable(mutexIo());
		defer self.queue.mutex.unlock(mutexIo());
		self.queue.jobs.append(self.allocator, job) catch {
			self.allocator.free(job.path);
			self.queue.failed = true;
		};
	}

	fn loop(self: *Walk) void {
		while (true) {
			self.queue.mutex.lockUncancelable(mutexIo());
			if (self.queue.failed or (self.queue.jobs.items.len == 0 and self.queue.active == 0)) {
				self.queue.mutex.unlock(mutexIo());
				return;
			}
			const job = self.queue.jobs.pop() orelse {
				self.queue.mutex.unlock(mutexIo());
				std.Thread.yield() catch {};
				continue;
			};
			self.queue.active += 1;
			self.queue.mutex.unlock(mutexIo());

			self.walkDir(job) catch {
				self.queue.mutex.lockUncancelable(mutexIo());
				self.queue.failed = true;
				self.queue.mutex.unlock(mutexIo());
			};
			self.allocator.free(job.path);

			self.queue.mutex.lockUncancelable(mutexIo());
			self.queue.active -= 1;
			self.queue.mutex.unlock(mutexIo());
		}
	}

	fn walkDir(self: *Walk, job: Job) !void {
		const z = try self.allocator.dupeSentinel(u8, if (job.path.len == 0) "/" else job.path, 0);
		defer self.allocator.free(z);
		const opened = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
		if (linux.errno(opened) != .SUCCESS) return;
		const fd: i32 = @intCast(opened);
		defer _ = linux.close(fd);

		self.path.clearRetainingCapacity();
		try self.path.appendSlice(self.allocator, job.path);
		const in_home = guardmod.hasPrefix(job.path, self.home);

		var buffer: [32 * 1024]u8 = undefined;
		while (true) {
			const read = linux.getdents64(fd, &buffer, buffer.len);
			if (linux.errno(read) != .SUCCESS or read == 0) return;

			var offset: usize = 0;
			while (offset < read) {
				const entry: *align(1) linux.dirent64 = @ptrCast(&buffer[offset]);
				if (entry.reclen == 0) return;
				offset += entry.reclen;

				const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
				if (entry_name.len == 0 or entry_name.len > 255 or entry_name[0] == '.') continue;

				self.path.shrinkRetainingCapacity(job.path.len);
				try self.path.append(self.allocator, '/');
				try self.path.appendSlice(self.allocator, entry_name);
				if (skip(self.path.items, entry_name, job.depth)) continue;

				var is_dir = entry.type == linux.DT.DIR;
				if (entry.type == linux.DT.UNKNOWN) {
					var st: linux.Statx = undefined;
					if (linux.errno(linux.statx(fd, @ptrCast(&entry.name), linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) continue;
					is_dir = std.posix.S.ISDIR(st.mode);
				}

				const home = in_home or guardmod.hasPrefix(self.path.items, self.home);
				const rank = job.depth + (if (home) @as(u16, 0) else 8);
				const id = try self.add(job.parent, entry_name, is_dir, rank);
				if (is_dir) self.push(.{ .path = try self.allocator.dupe(u8, self.path.items), .parent = id, .depth = job.depth +| 1 });
			}
		}
	}
};

const Tree = struct {
	walks: []Walk,
	bases: []const u32,

	fn locate(self: *const Tree, id: u32) struct { walk: *const Walk, local: u32 } {
		var t: usize = 0;
		while (id >= self.bases[t + 1]) t += 1;
		return .{ .walk = &self.walks[t], .local = id - self.bases[t] };
	}

	fn nameOf(self: *const Tree, id: u32) []const u8 {
		const at = self.locate(id);
		return at.walk.nameOf(at.local);
	}

	fn raw(self: *const Tree, id: u32) u32 {
		const at = self.locate(id);
		return at.walk.parents.items[at.local];
	}

	fn rank(self: *const Tree, id: u32) u16 {
		const at = self.locate(id);
		return at.walk.ranks.items[at.local];
	}
};

fn mutexIo() std.Io {
	return std.Io.Threaded.global_single_threaded.io();
}

fn skip(full: []const u8, entry_name: []const u8, depth: u16) bool {
	for (skipped_names) |junk| if (std.mem.eql(u8, entry_name, junk)) return true;
	if (depth > 2) return false;
	for (guardmod.protected_paths) |prefix| if (std.mem.eql(u8, full, prefix)) return true;
	for (skipped_paths) |prefix| if (std.mem.eql(u8, full, prefix)) return true;
	return false;
}

const Sort = struct {
	key: u64,
	id: u32,

	fn less(w: *const Tree, a: Sort, b: Sort) bool {
		if (a.key != b.key) return a.key < b.key;
		return std.mem.lessThan(u8, w.nameOf(a.id), w.nameOf(b.id));
	}
};

fn sortChunk(chunk: []Sort, walk: *const Tree) void {
	std.sort.pdq(Sort, chunk, walk, Sort.less);
}

fn sortParallel(allocator: Allocator, items: []Sort, walk: *const Tree, threads: usize) !void {
	const count = @max(1, @min(threads, items.len / 4096));
	var bounds: [max_threads + 1]usize = undefined;
	for (0..count + 1) |t| bounds[t] = items.len * t / count;

	var sorters: [max_threads]std.Thread = undefined;
	for (1..count) |t| sorters[t - 1] = try std.Thread.spawn(.{}, sortChunk, .{ items[bounds[t]..bounds[t + 1]], walk });
	sortChunk(items[0..bounds[1]], walk);
	for (sorters[0 .. count - 1]) |sorter| sorter.join();
	if (count == 1) return;

	const copy = try allocator.dupe(Sort, items);
	defer allocator.free(copy);
	var heads: [max_threads]usize = undefined;
	for (0..count) |t| heads[t] = bounds[t];
	for (items) |*out| {
		var best: ?usize = null;
		for (0..count) |t| {
			if (heads[t] == bounds[t + 1]) continue;
			if (best == null or Sort.less(walk, copy[heads[t]], copy[heads[best.?]])) best = t;
		}
		out.* = copy[heads[best.?]];
		heads[best.?] += 1;
	}
}

const Slot = struct {
	gram: u32,
	last: u32 = 0,
	count: u32 = 0,
	bytes: std.ArrayList(u8) = .empty,

	fn less(_: void, a: Slot, b: Slot) bool {
		return a.gram < b.gram;
	}
};

const Part = struct {
	walk: *const Tree,
	order: []const u32,
	remap: []const u32,
	starts: []u32,
	from: u32,
	to: u32,
	grams: Grams,
	names: std.ArrayList(u8) = .empty,
	failed: bool = false,

	fn deinit(self: *Part) void {
		self.names.deinit(self.grams.allocator);
		self.grams.deinit();
	}

	fn run(self: *Part) void {
		self.encode() catch {
			self.failed = true;
		};
	}

	fn encode(self: *Part) !void {
		const allocator = self.grams.allocator;
		var low: [256]u8 = undefined;
		var block = self.from;
		while (block < self.to) : (block += 1) {
			self.starts[block] = @intCast(self.names.items.len);
			var prev: []const u8 = "";
			var prev_parent: u32 = 0;
			const first = block * block_size;
			for (self.order[first..@min(first + block_size, self.order.len)]) |old| {
				const entry_name = self.walk.nameOf(old);
				const shared = std.mem.indexOfDiff(u8, prev, entry_name) orelse entry_name.len;
				try self.names.append(allocator, @intCast(shared));
				try self.names.append(allocator, @intCast(entry_name.len - shared));
				try self.names.appendSlice(allocator, entry_name[shared..]);
				prev = entry_name;

				const raw = self.walk.raw(old);
				const old_parent = raw & ~dir_bit;
				const parent = if (old_parent == none) none else self.remap[old_parent];
				try writeVarint(allocator, &self.names, zigzag(@as(i64, parent) - @as(i64, prev_parent)) << 1 | @intFromBool(raw & dir_bit != 0));
				prev_parent = parent;
				if (old_parent == none) continue;

				const text = std.ascii.lowerString(low[0..entry_name.len], entry_name);
				for (text, 0..) |c, i| {
					try self.grams.add(tag_uni | c, block);
					if (i + 2 <= text.len) try self.grams.add(tag_bi | @as(u32, c) << 8 | text[i + 1], block);
					if (i + 3 <= text.len) try self.grams.add(triOf(text[i..][0..3]), block);
				}
			}
		}
	}
};

fn mergePosts(parts: []Part, allocator: Allocator, keys: ?*std.ArrayList(Key), out: ?*std.Io.Writer) !usize {
	var at: [max_threads]usize = @splat(0);
	var post_len: usize = 0;
	var scratch: [10]u8 = undefined;

	while (true) {
		var gram: u32 = std.math.maxInt(u32);
		for (parts, 0..) |*part, t| {
			if (at[t] < part.grams.slots.items.len) gram = @min(gram, part.grams.slots.items[at[t]].gram);
		}
		if (gram == std.math.maxInt(u32)) return post_len;

		var key: Key = .{ .gram = gram, .count = 0, .off = @intCast(post_len) };
		var last: u32 = 0;
		for (parts, 0..) |*part, t| {
			if (at[t] >= part.grams.slots.items.len or part.grams.slots.items[at[t]].gram != gram) continue;
			const slot = part.grams.slots.items[at[t]];
			at[t] += 1;

			var cut: usize = 0;
			const first: u32 = @intCast(readVarint(slot.bytes.items, &cut));
			const head = encodeVarint(&scratch, first - last);
			if (out) |w| {
				try w.writeAll(head);
				try w.writeAll(slot.bytes.items[cut..]);
			}
			post_len += head.len + slot.bytes.items.len - cut;
			key.count += slot.count;
			last = slot.last;
		}
		if (keys) |list| try list.append(allocator, key);
	}
}

fn encodeVarint(buf: *[10]u8, value: u64) []const u8 {
	var v = value;
	var len: usize = 0;
	while (v >= 0x80) : (v >>= 7) {
		buf[len] = @as(u8, @truncate(v)) | 0x80;
		len += 1;
	}
	buf[len] = @truncate(v);
	return buf[0 .. len + 1];
}

const Grams = struct {
	allocator: Allocator,
	slots: std.ArrayList(Slot) = .empty,
	small: []u32,
	tri: std.AutoHashMapUnmanaged(u32, u32) = .empty,

	fn init(allocator: Allocator) !Grams {
		const small = try allocator.alloc(u32, 256 + 65536);
		@memset(small, none);
		return .{ .allocator = allocator, .small = small };
	}

	fn deinit(self: *Grams) void {
		for (self.slots.items) |*slot| slot.bytes.deinit(self.allocator);
		self.slots.deinit(self.allocator);
		self.allocator.free(self.small);
		self.tri.deinit(self.allocator);
	}

	fn add(self: *Grams, gram: u32, block: u32) !void {
		const index = if (gram < tag_bi) blk: {
			const entry = try self.tri.getOrPut(self.allocator, gram);
			if (!entry.found_existing) entry.value_ptr.* = none;
			break :blk entry.value_ptr;
		} else &self.small[if (gram >= tag_uni) gram - tag_uni else 256 + (gram - tag_bi)];

		if (index.* == none) {
			index.* = @intCast(self.slots.items.len);
			try self.slots.append(self.allocator, .{ .gram = gram });
		}

		const slot = &self.slots.items[index.*];
		if (slot.count > 0 and slot.last == block) return;
		try writeVarint(self.allocator, &slot.bytes, block - slot.last);
		slot.last = block;
		slot.count += 1;
	}
};

pub fn build(io: Io, allocator: Allocator, root: []const u8, home: []const u8, out_path: []const u8, built_ms: i64) !void {
	const root_name = std.mem.trimEnd(u8, root, "/");
	if (root_name.len > 255) return error.RootTooLong;

	var queue: Queue = .{};
	defer {
		for (queue.jobs.items) |job| allocator.free(job.path);
		queue.jobs.deinit(allocator);
	}

	const threads = @min(std.Thread.getCpuCount() catch 1, max_threads);
	var walks: [max_threads]Walk = undefined;
	for (walks[0..threads], 0..) |*walk, t| walk.* = .{ .allocator = allocator, .queue = &queue, .thread = @intCast(t), .home = home };
	defer for (walks[0..threads]) |*walk| walk.deinit();

	const root_id = try walks[0].add(none, root_name, true, std.math.maxInt(u16));
	try queue.jobs.append(allocator, .{ .path = try allocator.dupe(u8, root_name), .parent = root_id, .depth = 0 });

	var workers: [max_threads]std.Thread = undefined;
	var spawned: usize = 0;
	defer for (workers[0..spawned]) |worker| worker.join();
	for (walks[1..threads], workers[0 .. threads - 1]) |*walk, *worker| {
		worker.* = try std.Thread.spawn(.{}, Walk.loop, .{walk});
		spawned += 1;
	}
	walks[0].loop();
	for (workers[0..spawned]) |worker| worker.join();
	spawned = 0;
	if (queue.failed) return error.WalkFailed;

	var bases: [max_threads + 1]u32 = undefined;
	bases[0] = 0;
	for (walks[0..threads], 0..) |walk, t| bases[t + 1] = bases[t] + @as(u32, @intCast(walk.parents.items.len));
	const total = bases[threads];

	for (walks[0..threads]) |*walk| {
		for (walk.parents.items) |*raw| {
			const handle = raw.* & ~dir_bit;
			if (handle == none) continue;
			raw.* = (bases[handle >> thread_shift] + (handle & local_mask)) | (raw.* & dir_bit);
		}
	}
	const tree: Tree = .{ .walks = walks[0..threads], .bases = bases[0 .. threads + 1] };

	const order = try allocator.alloc(u32, total);
	defer allocator.free(order);
	{
		const sorted = try allocator.alloc(Sort, total);
		defer allocator.free(sorted);
		for (sorted, 0..) |*slot, i| {
			const id: u32 = @intCast(i);
			const entry_name = tree.nameOf(id);
			var prefix: [2]u8 = .{ 0, 0 };
			@memcpy(prefix[0..@min(2, entry_name.len)], entry_name[0..@min(2, entry_name.len)]);
			const parent: u64 = tree.raw(id) & ~dir_bit;
			slot.* = .{ .key = @as(u64, tree.rank(id)) << 47 | parent << 16 | std.mem.readInt(u16, &prefix, .big), .id = id };
		}
		try sortParallel(allocator, sorted, &tree, threads);
		for (sorted, order) |slot, *id| id.* = slot.id;
	}
	for (walks[0..threads]) |*walk| {
		walk.ranks.clearAndFree(allocator);
		walk.path.clearAndFree(allocator);
	}

	const remap = try allocator.alloc(u32, total);
	defer allocator.free(remap);
	for (order, 0..) |old, new| remap[old] = @intCast(new);

	const blocks: u32 = (total + block_size - 1) / block_size;
	const starts = try allocator.alloc(u32, blocks + 1);
	defer allocator.free(starts);

	var parts: [max_threads]Part = undefined;
	const used = @max(1, @min(threads, blocks));
	for (parts[0..used], 0..) |*part, t| part.* = .{
		.walk = &tree,
		.order = order,
		.remap = remap,
		.starts = starts,
		.from = @intCast(blocks * t / used),
		.to = @intCast(blocks * (t + 1) / used),
		.grams = try Grams.init(allocator),
	};
	defer for (parts[0..used]) |*part| part.deinit();

	var encoders: [max_threads]std.Thread = undefined;
	for (parts[1..used], encoders[0 .. used - 1]) |*part, *encoder| encoder.* = try std.Thread.spawn(.{}, Part.run, .{part});
	parts[0].run();
	for (encoders[0 .. used - 1]) |encoder| encoder.join();

	var names_len: usize = 0;
	for (parts[0..used]) |*part| {
		if (part.failed) return error.EncodeFailed;
		for (starts[part.from..part.to]) |*start| start.* += @intCast(names_len);
		names_len += part.names.items.len;
		std.sort.pdq(Slot, part.grams.slots.items, {}, Slot.less);
	}
	starts[blocks] = @intCast(names_len);

	var keys: std.ArrayList(Key) = .empty;
	defer keys.deinit(allocator);
	const post_len = try mergePosts(parts[0..used], allocator, &keys, null);

	const header: Header = .{ .count = total, .blocks = blocks, .keys = @intCast(keys.items.len), .root = remap[0], .built_ms = built_ms, .names_len = names_len, .post_len = post_len };

	const temp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ out_path, linux.getpid() });
	defer allocator.free(temp);
	if (std.fs.path.dirname(out_path)) |parent_dir| try std.Io.Dir.cwd().createDirPath(io, parent_dir);

	var file = try std.Io.Dir.cwd().createFile(io, temp, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
	errdefer {
		file.close(io);
		std.Io.Dir.cwd().deleteFile(io, temp) catch {};
	}

	var buffer: [64 * 1024]u8 = undefined;
	var writer = file.writer(io, &buffer);
	const w = &writer.interface;
	try w.writeAll(std.mem.asBytes(&header));
	try w.writeAll(std.mem.sliceAsBytes(starts));
	try w.writeAll(std.mem.sliceAsBytes(keys.items));
	for (parts[0..used]) |*part| try w.writeAll(part.names.items);
	_ = try mergePosts(parts[0..used], allocator, null, w);
	try w.flush();
	file.close(io);
	try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), out_path, io);
}

pub fn command(io: Io, args: []const []const u8) !void {
	if (args.len < 5) return error.Usage;
	_ = linux.syscall3(.setpriority, 0, 0, 19);
	try build(io, std.heap.smp_allocator, args[2], args[3], args[4], std.Io.Clock.real.now(io).toMilliseconds());
}

fn lower(c: u8) u32 {
	return std.ascii.toLower(c);
}

fn triOf(bytes: *const [3]u8) u32 {
	return lower(bytes[0]) << 16 | lower(bytes[1]) << 8 | lower(bytes[2]);
}

fn zigzag(value: i64) u64 {
	return @bitCast((value << 1) ^ (value >> 63));
}

fn unzigzag(value: u64) i64 {
	return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @bitCast(value & 1));
}

fn writeVarint(allocator: Allocator, out: *std.ArrayList(u8), value: u64) !void {
	var v = value;
	while (v >= 0x80) : (v >>= 7) try out.append(allocator, @as(u8, @truncate(v)) | 0x80);
	try out.append(allocator, @truncate(v));
}

fn readVarint(bytes: []const u8, at: *usize) u64 {
	var value: u64 = 0;
	var shift: u6 = 0;
	while (true) {
		const byte = bytes[at.*];
		at.* += 1;
		value |= @as(u64, byte & 0x7f) << shift;
		if (byte & 0x80 == 0) return value;
		shift +|= 7;
	}
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

	for ([_][]const u8{ "Docs/deep/more", "node_modules/pkg", "Photos", ".secret", "many" }) |sub| {
		const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, sub });
		defer allocator.free(p);
		try std.Io.Dir.cwd().createDirPath(io, p);
	}
	for ([_][]const u8{ "Report.pdf", "Docs/deep/more/old-report.txt", "node_modules/pkg/report.js", "Photos/cat.png", ".secret/report.key", ".hidden-report" }) |sub| {
		const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, sub });
		defer allocator.free(p);
		var file = try std.Io.Dir.cwd().createFile(io, p, .{});
		file.close(io);
	}
	for (0..300) |i| {
		const p = try std.fmt.allocPrint(allocator, "{s}/many/file-{d}.txt", .{ root, i });
		defer allocator.free(p);
		var file = try std.Io.Dir.cwd().createFile(io, p, .{});
		file.close(io);
	}

	const index_path = try std.fmt.allocPrint(allocator, "{s}/files.idx", .{root});
	defer allocator.free(index_path);
	try build(io, allocator, root, root, index_path, 42);

	var index = try load(io, index_path);
	defer index.deinit();
	try std.testing.expectEqual(@as(i64, 42), index.built_ms);

	var hits: [400]u32 = undefined;
	var buffer: [4096]u8 = undefined;
	var buf: [256]u8 = undefined;

	try std.testing.expectEqual(@as(usize, 2), index.search("report", &hits));
	try std.testing.expectEqualStrings("Report.pdf", index.item(hits[0], &buf).name);
	try std.testing.expectEqualStrings("old-report.txt", index.item(hits[1], &buf).name);
	const full = try std.fmt.allocPrint(allocator, "{s}/Docs/deep/more/old-report.txt", .{root});
	defer allocator.free(full);
	try std.testing.expectEqualStrings(full, index.path(&buffer, hits[1]));

	try std.testing.expectEqual(@as(usize, 1), index.search("ca", &hits));
	try std.testing.expectEqualStrings("cat.png", index.item(hits[0], &buf).name);
	try std.testing.expectEqual(@as(usize, 1), index.search("g", &hits));
	try std.testing.expectEqual(@as(usize, 1), index.search("photos", &hits));
	try std.testing.expect(index.item(hits[0], &buf).dir);
	try std.testing.expectEqual(@as(usize, 0), index.search("zzzq", &hits));
	try std.testing.expectEqual(@as(usize, 0), index.search("secret", &hits));

	try std.testing.expectEqual(@as(usize, 300), index.search("file-", &hits));
	for (hits[0..300]) |id| {
		const got = index.path(&buffer, id);
		try std.testing.expect(std.mem.indexOf(u8, got, "/many/file-") != null);
		try std.testing.expect(std.mem.endsWith(u8, got, ".txt"));
	}
	try std.testing.expectEqual(@as(usize, 1), index.search("file-277.t", &hits));
	try std.testing.expectEqualStrings("file-277.txt", index.item(hits[0], &buf).name);
}
