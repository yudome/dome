const std = @import("std");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;

const max_threads = 16;
const work_per_thread = 4096;
const chunks_per_thread = 16;

pub const Dirs = struct {
	depth: []u8,
	home: []bool,

	pub fn init(allocator: Allocator, idx: *const index.Index, home: []const u8) !Dirs {
		const depth = try allocator.alloc(u8, idx.dirs.len);
		errdefer allocator.free(depth);
		const inside = try allocator.alloc(bool, idx.dirs.len);
		const home_id = idx.find(std.mem.trim(u8, home, "/"));
		const home_at = if (home_id == index.none) null else idx.dirIndex(home_id);
		for (idx.dirs, 0..) |dir, at| {
			const root = dir.up == index.none or dir.up >= at;
			depth[at] = if (root) 0 else depth[dir.up] +| 1;
			inside[at] = home_at == at or (!root and inside[dir.up]);
		}
		return .{ .depth = depth, .home = inside };
	}

	pub fn deinit(self: *Dirs, allocator: Allocator) void {
		allocator.free(self.depth);
		allocator.free(self.home);
	}
};

pub const Hit = struct {
	key: u64,
	hash: u64,

	pub fn id(self: Hit) u32 {
		return @truncate(self.key);
	}

	pub fn quality(self: Hit) u8 {
		return @intCast(self.key >> 62);
	}

	pub fn home(self: Hit) bool {
		return (self.key >> 61) & 1 == 0;
	}

	pub fn depth(self: Hit) u8 {
		return @truncate(self.key >> 53);
	}

	fn less(_: void, a: Hit, b: Hit) bool {
		return a.key < b.key;
	}
};

pub fn keyOf(q: u8, home: bool, depth: u8, id: u32) u64 {
	return @as(u64, q) << 62 | @as(u64, @intFromBool(!home)) << 61 | @as(u64, depth) << 53 | id;
}

pub fn quality(name: []const u8, needle: []const u8) u8 {
	if (!index.isAscii(name) or !index.isAscii(needle)) return foldedQuality(name, needle);
	if (name.len < needle.len) return 3;
	if (index.tailMatch(name, 0, needle)) return if (name.len == needle.len) 0 else 1;
	for (1..name.len - needle.len + 1) |at| {
		if (!index.tailMatch(name, at, needle)) continue;
		return if (std.mem.indexOfScalar(u8, " -_.", index.lower(name[at - 1])) != null) 2 else 3;
	}
	return 3;
}

fn foldedQuality(name: []const u8, needle: []const u8) u8 {
	var buf: [256]u8 = undefined;
	const folded = index.fold(&buf, name);
	if (std.mem.eql(u8, folded, needle)) return 0;
	if (std.mem.startsWith(u8, folded, needle)) return 1;
	const at = std.mem.indexOf(u8, folded, needle) orelse return 3;
	return if (at > 0 and std.mem.indexOfScalar(u8, " -_.", folded[at - 1]) != null) 2 else 3;
}

const Heap = struct {
	items: []Hit,
	len: usize = 0,

	fn full(self: *const Heap) bool {
		return self.len == self.items.len;
	}

	fn push(self: *Heap, hit: Hit) void {
		if (self.len < self.items.len) {
			var at = self.len;
			self.items[at] = hit;
			self.len += 1;
			while (at > 0) {
				const up = (at - 1) / 2;
				if (self.items[up].key >= self.items[at].key) break;
				std.mem.swap(Hit, &self.items[up], &self.items[at]);
				at = up;
			}
			return;
		}
		self.items[0] = hit;
		var at: usize = 0;
		while (true) {
			var big = at;
			for ([_]usize{ 2 * at + 1, 2 * at + 2 }) |child| {
				if (child < self.len and self.items[child].key > self.items[big].key) big = child;
			}
			if (big == at) return;
			std.mem.swap(Hit, &self.items[big], &self.items[at]);
			at = big;
		}
	}
};

const Distinct = struct {
	items: []Hit,
	len: usize = 0,
	worst: usize = 0,

	fn full(self: *const Distinct) bool {
		return self.len == self.items.len;
	}

	fn push(self: *Distinct, hit: Hit) void {
		for (self.items[0..self.len]) |*item| {
			if (item.hash != hit.hash) continue;
			if (hit.key >= item.key) return;
			item.* = hit;
			return self.rescan();
		}
		if (self.len < self.items.len) {
			self.items[self.len] = hit;
			self.len += 1;
		} else self.items[self.worst] = hit;
		self.rescan();
	}

	fn rescan(self: *Distinct) void {
		self.worst = 0;
		for (self.items[0..self.len], 0..) |item, at| {
			if (item.key > self.items[self.worst].key) self.worst = at;
		}
	}
};

const Worker = struct {
	pad: [64]u8 align(64) = undefined,
	idx: *const index.Index,
	dirs: *const Dirs,
	needle: []const u8,
	ascii: bool,
	all: Heap,
	distinct: Distinct,
	matched: usize = 0,
	parent: u32 = index.none,
	dir: ?usize = null,
	tail: [64]u8 = undefined,

	pub fn hit(self: *Worker, id: u32, entry: index.Item) bool {
		self.matched += 1;
		if (self.all.full() and self.distinct.full() and self.ascii) {
			const floor: u8 = if (entry.name.len >= self.needle.len and index.tailMatch(entry.name, 0, self.needle)) 0 else 2;
			const least = keyOf(floor, true, 0, 0);
			if (least >= self.all.items[0].key and least >= self.distinct.items[self.distinct.worst].key) return true;
		}
		if (entry.parent != self.parent) {
			self.parent = entry.parent;
			const dirs = self.idx.dirs;
			const after = if (self.dir) |at| at + 1 else dirs.len;
			self.dir = if (after < dirs.len and dirs[after].id == entry.parent) after else self.idx.dirIndex(entry.parent);
		}
		const depth: u8 = if (self.dir) |at| self.dirs.depth[at] +| 1 else 0;
		const home = if (self.dir) |at| self.dirs.home[at] else false;
		const key = keyOf(quality(entry.name, self.needle), home, depth, id);
		const keep_all = !self.all.full() or key < self.all.items[0].key;
		const keep_distinct = !self.distinct.full() or key < self.distinct.items[self.distinct.worst].key;
		if (!keep_all and !keep_distinct) return true;
		const found: Hit = .{ .key = key, .hash = std.hash.Wyhash.hash(0, entry.name) };
		if (keep_all) self.all.push(found);
		if (keep_distinct) self.distinct.push(found);
		return true;
	}

	fn run(self: *Worker, scanner: index.Scanner, next: *std.atomic.Value(u32), chunk: u32, groups: u32) void {
		var walk = scanner;
		while (true) {
			const at = next.fetchAdd(1, .monotonic);
			const from = at * chunk;
			if (from >= groups) return;
			if (!walk.run(from, from + chunk, self)) return;
		}
	}
};

const Job = struct {
	workers: []Worker,
	scanner: index.Scanner,
	next: *std.atomic.Value(u32),
	chunk: u32,
	groups: u32,

	fn work(self: *const Job, slot: usize) void {
		if (slot < self.workers.len) self.workers[slot].run(self.scanner, self.next, self.chunk, self.groups);
	}
};

pub const Pool = struct {
	io: std.Io,
	threads: []std.Thread,
	mutex: std.Io.Mutex = .init,
	epoch: std.atomic.Value(u32) = .init(0),
	left: std.atomic.Value(u32) = .init(0),
	job: ?*const Job = null,

	pub fn create(allocator: Allocator, io: std.Io) !*Pool {
		const cpus = std.Thread.getCpuCount() catch 1;
		const self = try allocator.create(Pool);
		self.* = .{ .io = io, .threads = try allocator.alloc(std.Thread, @min(cpus, max_threads) - 1) };
		for (self.threads, 1..) |*thread, slot| thread.* = try std.Thread.spawn(.{}, loop, .{ self, slot });
		return self;
	}

	pub fn size(self: *const Pool) usize {
		return self.threads.len + 1;
	}

	fn loop(self: *Pool, slot: usize) void {
		var seen: u32 = 0;
		while (true) {
			while (self.epoch.load(.acquire) == seen) self.io.futexWaitUncancelable(u32, &self.epoch.raw, seen);
			seen = self.epoch.load(.acquire);
			self.job.?.work(slot);
			if (self.left.fetchSub(1, .acq_rel) == 1) self.io.futexWake(u32, &self.left.raw, 1);
		}
	}

	fn run(self: *Pool, job: *const Job) void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		if (job.workers.len == 1 or self.threads.len == 0) return job.work(0);
		self.job = job;
		self.left.store(@intCast(self.threads.len), .release);
		_ = self.epoch.fetchAdd(1, .release);
		self.io.futexWake(u32, &self.epoch.raw, std.math.maxInt(u32));
		job.work(0);
		while (true) {
			const left = self.left.load(.acquire);
			if (left == 0) break;
			self.io.futexWaitUncancelable(u32, &self.left.raw, left);
		}
	}
};

pub const Result = struct {
	distinct: []Hit,
	all: []Hit,
	matched: usize,
};

pub fn top(allocator: Allocator, pool: *Pool, idx: *const index.Index, dirs: *const Dirs, query: []const u8, limit: usize) !Result {
	const empty: Result = .{ .distinct = &.{}, .all = &.{}, .matched = 0 };
	if (limit == 0 or query.len == 0 or query.len > 255) return empty;
	var needle_buf: [256]u8 = undefined;
	const needle = index.fold(&needle_buf, query);
	const groups = idx.groups(query.len);
	if (groups == 0) return empty;
	const count = std.math.clamp(idx.estimate(query) / work_per_thread, 1, @min(pool.size(), groups));

	const workers = try allocator.alloc(Worker, count);
	for (workers) |*worker| {
		worker.* = .{
			.idx = idx,
			.dirs = dirs,
			.needle = needle,
			.ascii = index.isAscii(needle),
			.all = .{ .items = try allocator.alloc(Hit, limit) },
			.distinct = .{ .items = try allocator.alloc(Hit, limit) },
		};
	}

	const scanner = idx.scanner(query);
	const chunk: u32 = @intCast(@max(1, groups / (count * chunks_per_thread)));
	var next: std.atomic.Value(u32) = .init(0);
	const job: Job = .{ .workers = workers, .scanner = scanner, .next = &next, .chunk = chunk, .groups = groups };
	pool.run(&job);

	var all: std.ArrayList(Hit) = .empty;
	var distinct: std.ArrayList(Hit) = .empty;
	var matched: usize = 0;
	for (workers) |worker| {
		matched += worker.matched;
		try all.appendSlice(allocator, worker.all.items[0..worker.all.len]);
		try distinct.appendSlice(allocator, worker.distinct.items[0..worker.distinct.len]);
	}
	std.mem.sort(Hit, all.items, {}, Hit.less);
	std.mem.sort(Hit, distinct.items, {}, Hit.less);

	var names: std.AutoHashMapUnmanaged(u64, void) = .empty;
	var kept: usize = 0;
	for (distinct.items) |found| {
		if (kept == limit) break;
		if ((try names.getOrPut(allocator, found.hash)).found_existing) continue;
		distinct.items[kept] = found;
		kept += 1;
	}
	return .{ .distinct = distinct.items[0..kept], .all = all.items[0..@min(all.items.len, limit)], .matched = matched };
}

test "quality ranks exact, prefix, word and inner matches" {
	try std.testing.expectEqual(@as(u8, 0), quality("README", "readme"));
	try std.testing.expectEqual(@as(u8, 1), quality("README.md", "readme"));
	try std.testing.expectEqual(@as(u8, 2), quality("old-readme", "readme"));
	try std.testing.expectEqual(@as(u8, 3), quality("xreadme", "readme"));
	try std.testing.expectEqual(@as(u8, 2), quality("ÜBER_readme", "readme"));
	try std.testing.expectEqual(@as(u8, 0), quality("ÜBER", "über"));
}

test "keys order quality, then home, then depth, then id" {
	try std.testing.expect(keyOf(0, false, 9, 9) < keyOf(1, true, 0, 0));
	try std.testing.expect(keyOf(1, true, 9, 9) < keyOf(1, false, 0, 0));
	try std.testing.expect(keyOf(1, true, 2, 9) < keyOf(1, true, 3, 0));
	const hit: Hit = .{ .key = keyOf(2, true, 7, 1234), .hash = 0 };
	try std.testing.expectEqual(@as(u32, 1234), hit.id());
	try std.testing.expectEqual(@as(u8, 2), hit.quality());
	try std.testing.expect(hit.home());
	try std.testing.expectEqual(@as(u8, 7), hit.depth());
}

test "distinct keeps the best hit of each name" {
	var items: [2]Hit = undefined;
	var distinct: Distinct = .{ .items = &items };
	for ([_][2]u64{ .{ 5, 1 }, .{ 3, 1 }, .{ 9, 2 }, .{ 4, 3 }, .{ 7, 3 }, .{ 8, 4 } }) |pair| {
		const hit: Hit = .{ .key = pair[0], .hash = pair[1] };
		if (distinct.full() and hit.key >= distinct.items[distinct.worst].key) continue;
		distinct.push(hit);
	}
	std.mem.sort(Hit, &items, {}, Hit.less);
	try std.testing.expectEqual(@as(u64, 3), items[0].key);
	try std.testing.expectEqual(@as(u64, 4), items[1].key);
}

test "the heap keeps the smallest keys" {
	var items: [3]Hit = undefined;
	var heap: Heap = .{ .items = &items };
	for ([_]u64{ 9, 4, 7, 1, 8, 2, 6 }) |key| {
		if (heap.full() and key >= heap.items[0].key) continue;
		heap.push(.{ .key = key, .hash = 0 });
	}
	std.mem.sort(Hit, &items, {}, Hit.less);
	try std.testing.expectEqual(@as(u64, 1), items[0].key);
	try std.testing.expectEqual(@as(u64, 2), items[1].key);
	try std.testing.expectEqual(@as(u64, 4), items[2].key);
}
