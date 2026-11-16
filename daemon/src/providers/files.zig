const std = @import("std");
const linux = std.os.linux;
const guardmod = @import("disk/guard.zig");
const proc = @import("../primitives/proc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const magic = "YUDFILE\x00";
pub const version: u32 = 4;
const dir_bit: u32 = 1 << 31;
const none: u32 = dir_bit - 1;
const block_size = 64;
const max_lists = 8;
const max_threads = 8;
const tag_bi: u32 = 1 << 24;
const tag_uni: u32 = 2 << 24;

const skipped_paths = [_][]const u8{ "/tmp", "/var", "/opt", "/nix", "/snap", "/lost+found" };
const skipped_names = [_][]const u8{ "node_modules", "__pycache__", "zig-out" };

const Header = extern struct {
	magic: [8]u8 = magic.*,
	version: u32 = version,
	count: u32 = 0,
	blocks: u32 = 0,
	keys: u32 = 0,
	built_ms: i64 = 0,
	names_at: u64 = 0,
	names_len: u64 = 0,
	post_at: u64 = 0,
	post_len: u64 = 0,
	starts_at: u64 = 0,
	keys_at: u64 = 0,
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

	pub fn search(self: *const Index, query: []const u8, out: []u32) usize {
		if (query.len == 0 or query.len > 255 or out.len == 0) return 0;
		var needle_buf: [256]u8 = undefined;
		const needle = fold(&needle_buf, query);
		const ascii = isAscii(needle);
		var folded: [256]u8 = undefined;
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
				if (id == self.root or !matches(entry.name, needle, ascii, &folded)) continue;
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
	const starts_len = (@as(u64, header.blocks) + 1) * 4;
	const keys_len = @as(u64, header.keys) * @sizeOf(Key);
	if (header.names_at + header.names_len > mapped.len or header.post_at + header.post_len > mapped.len) return error.BadIndex;
	if (header.starts_at % 4 != 0 or header.starts_at + starts_len > mapped.len or header.keys_at + keys_len != mapped.len) return error.BadIndex;

	return .{
		.mapped = mapped,
		.starts = @as([*]const u32, @ptrCast(@alignCast(mapped.ptr + header.starts_at)))[0 .. header.blocks + 1],
		.keys = @as([*]const Key, @ptrCast(@alignCast(mapped.ptr + header.keys_at)))[0..header.keys],
		.names = mapped[header.names_at..][0..header.names_len],
		.post = mapped[header.post_at..][0..header.post_len],
		.count = header.count,
		.root = 0,
		.built_ms = header.built_ms,
	};
}

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

const Store = struct {
	allocator: Allocator,
	slots: std.ArrayList(Slot) = .empty,
	chunks: std.ArrayList(Chunk) = .empty,
	index: []u32,

	fn init(allocator: Allocator) !Store {
		const index = try allocator.alloc(u32, 256 + 65536 + (1 << 18));
		@memset(index, none);
		return .{ .allocator = allocator, .index = index };
	}

	fn deinit(self: *Store) void {
		self.slots.deinit(self.allocator);
		self.chunks.deinit(self.allocator);
		self.allocator.free(self.index);
	}

	fn post(self: *Store, gram: u32, block: u32) !void {
		const index = &self.index[if (gram >= tag_uni) gram - tag_uni else if (gram >= tag_bi) 256 + (gram - tag_bi) else 256 + 65536 + gram];
		if (index.* == none) {
			index.* = @intCast(self.slots.items.len);
			try self.slots.append(self.allocator, .{ .gram = gram });
		}
		const slot = &self.slots.items[index.*];
		if (slot.count > 0 and slot.last == block) return;
		var scratch: [10]u8 = undefined;
		for (encodeVarint(&scratch, block - slot.last)) |byte| {
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
		slot.len += @intCast(encodeVarint(&scratch, block - slot.last).len);
		slot.last = block;
		slot.count += 1;
	}

	fn chain(self: *const Store, slot: Slot, w: *std.Io.Writer) !void {
		var left: usize = slot.len;
		var at = slot.head;
		while (left > 0) : (at = self.chunks.items[at].next) {
			const take = @min(left, chunk_data);
			try w.writeAll(self.chunks.items[at].data[0..take]);
			left -= take;
		}
	}
};

fn writeStore(allocator: Allocator, store: *Store, w: *std.Io.Writer, keys: *std.ArrayList(Key), base: u64) !u64 {
	std.sort.pdq(Slot, store.slots.items, {}, struct {
		fn less(_: void, a: Slot, b: Slot) bool {
			return a.gram < b.gram;
		}
	}.less);
	var off = base;
	for (store.slots.items) |slot| {
		try keys.append(allocator, .{ .gram = slot.gram, .count = slot.count, .off = @intCast(off) });
		try store.chain(slot, w);
		off += slot.len;
	}
	return off;
}

const FeedItem = struct {
	off: u32,
	len: u8,
	block: u32,
};

const Feed = struct {
	names: std.ArrayList(u8) = .empty,
	items: std.ArrayList(FeedItem) = .empty,

	fn deinit(self: *Feed, allocator: Allocator) void {
		self.names.deinit(allocator);
		self.items.deinit(allocator);
	}

	fn clear(self: *Feed) void {
		self.names.clearRetainingCapacity();
		self.items.clearRetainingCapacity();
	}
};

const Poster = struct {
	allocator: Allocator,
	store: Store,
	tri: bool,
	seen: [(256 + 65536 + (1 << 18)) / 64]u64 = @splat(0),
	touched: std.ArrayList(u32) = .empty,
	block: u32 = 0,
	thread: ?std.Thread = null,
	start: std.Io.Semaphore = .{},
	done: std.Io.Semaphore = .{},
	failed: bool = false,

	fn deinit(self: *Poster) void {
		self.store.deinit();
		self.touched.deinit(self.allocator);
	}

	fn feed(self: *Poster, batch: *const Feed) !void {
		var low: [256]u8 = undefined;
		for (batch.items.items) |item| {
			if (item.block != self.block) try self.flush(item.block);
			const text = fold(&low, batch.names.items[item.off..][0..item.len]);
			if (self.tri) {
				var i: usize = 0;
				while (i + 3 <= text.len) : (i += 1) {
					const tri = triOf(text[i..][0..3]);
					try self.mark(256 + 65536 + tri, tri);
				}
				continue;
			}
			if (text.len == 1) try self.mark(text[0], tag_uni | text[0]);
			var i: usize = 0;
			while (i + 2 <= text.len) : (i += 1) {
				const pair = @as(u32, text[i]) << 8 | text[i + 1];
				try self.mark(256 + pair, tag_bi | pair);
			}
		}
	}

	fn mark(self: *Poster, bit: u32, gram: u32) !void {
		const word = &self.seen[bit >> 6];
		const mask = @as(u64, 1) << @intCast(bit & 63);
		if (word.* & mask != 0) return;
		word.* |= mask;
		try self.touched.append(self.allocator, gram);
	}

	fn flush(self: *Poster, next: u32) !void {
		const pairs = self.touched.items.len;
		for (0..pairs) |at| {
			const gram = self.touched.items[at];
			if (gram < tag_bi or gram >= tag_uni) continue;
			try self.mark((gram >> 8) & 0xff, tag_uni | ((gram >> 8) & 0xff));
			try self.mark(gram & 0xff, tag_uni | (gram & 0xff));
		}
		for (self.touched.items) |gram| {
			try self.store.post(gram, self.block);
			const bit = if (gram >= tag_uni) gram - tag_uni else if (gram >= tag_bi) 256 + (gram - tag_bi) else 256 + 65536 + gram;
			self.seen[bit >> 6] = 0;
		}
		self.touched.clearRetainingCapacity();
		self.block = next;
	}
};

const Posters = struct {
	io: Io,
	allocator: Allocator,
	posters: [2]*Poster,
	feeds: [2]Feed = .{ .{}, .{} },
	filling: usize = 0,
	shipped: usize = 0,
	busy: bool = false,
	stop: bool = false,

	fn spawn(self: *Posters) void {
		for (self.posters) |poster| poster.thread = std.Thread.spawn(.{}, worker, .{ self, poster }) catch null;
	}

	fn deinit(self: *Posters) void {
		@atomicStore(bool, &self.stop, true, .release);
		for (self.posters) |poster| if (poster.thread) |thread| {
			poster.start.post(self.io);
			thread.join();
		};
		for (&self.feeds) |*feed| feed.deinit(self.allocator);
	}

	fn add(self: *Posters, entry_name: []const u8, block: u32) !void {
		const feed = &self.feeds[self.filling];
		try feed.items.append(self.allocator, .{ .off = @intCast(feed.names.items.len), .len = @intCast(entry_name.len), .block = block });
		try feed.names.appendSlice(self.allocator, entry_name);
	}

	fn ship(self: *Posters) !void {
		try self.wait();
		self.shipped = self.filling;
		for (self.posters) |poster| {
			if (poster.thread == null) try poster.feed(&self.feeds[self.shipped]) else poster.start.post(self.io);
		}
		self.busy = true;
		self.filling = 1 - self.filling;
		self.feeds[self.filling].clear();
	}

	fn wait(self: *Posters) !void {
		if (!self.busy) return;
		for (self.posters) |poster| if (poster.thread != null) poster.done.waitUncancelable(self.io);
		self.busy = false;
		for (self.posters) |poster| if (@atomicLoad(bool, &poster.failed, .acquire)) return error.PostFailed;
	}

	fn finish(self: *Posters) !void {
		try self.ship();
		try self.wait();
		for (self.posters) |poster| try poster.flush(0);
	}

	fn worker(self: *Posters, poster: *Poster) void {
		while (true) {
			poster.start.waitUncancelable(self.io);
			if (@atomicLoad(bool, &self.stop, .acquire)) return;
			poster.feed(&self.feeds[self.shipped]) catch @atomicStore(bool, &poster.failed, true, .release);
			poster.done.post(self.io);
		}
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

	fn add(self: *Encoder, entry_name: []const u8, parent: u32, dir: bool) !u32 {
		const id = self.count;
		if (id % block_size == 0) {
			try self.starts.append(self.allocator, @intCast(self.names_len));
			self.prev_len = 0;
			self.prev_parent = 0;
		}

		const shared = std.mem.indexOfDiff(u8, self.prev[0..self.prev_len], entry_name) orelse entry_name.len;
		var scratch: [10]u8 = undefined;
		const tail = encodeVarint(&scratch, zigzag(@as(i64, parent) - @as(i64, self.prev_parent)) << 1 | @intFromBool(dir));
		try self.w.writeAll(&.{ @intCast(shared), @intCast(entry_name.len - shared) });
		try self.w.writeAll(entry_name[shared..]);
		try self.w.writeAll(tail);
		self.names_len += 2 + entry_name.len - shared + tail.len;
		@memcpy(self.prev[shared..entry_name.len], entry_name[shared..]);
		self.prev_len = entry_name.len;
		self.prev_parent = parent;

		if (parent != none) try self.posters.add(entry_name, id / block_size);
		self.count += 1;
		return id;
	}

	fn finish(self: *Encoder) !void {
		try self.posters.finish();
		try self.starts.append(self.allocator, @intCast(self.names_len));
	}
};

const Dir = struct {
	path: []u8,
	id: u32,
	depth: u16,
};

const Child = struct {
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
	failed: bool = false,

	fn deinit(self: *Lister) void {
		self.children.deinit(self.allocator);
		self.names.deinit(self.allocator);
		self.path.deinit(self.allocator);
	}

	fn reset(self: *Lister) void {
		self.children.clearRetainingCapacity();
		self.names.clearRetainingCapacity();
	}

	fn run(self: *Lister, dirs: []const Dir, results: []Listing, next: *std.atomic.Value(usize)) void {
		while (true) {
			const at = next.fetchAdd(1, .monotonic);
			if (at >= dirs.len) return;
			results[at] = self.list(dirs[at]) catch blk: {
				self.failed = true;
				break :blk .{ .lister = self.index, .from = 0, .to = 0 };
			};
		}
	}

	fn list(self: *Lister, dir: Dir) !Listing {
		const from: u32 = @intCast(self.children.items.len);
		const z = try self.allocator.dupeSentinel(u8, if (dir.path.len == 0) "/" else dir.path, 0);
		defer self.allocator.free(z);
		const opened = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
		if (linux.errno(opened) != .SUCCESS) return .{ .lister = self.index, .from = from, .to = from };
		const fd: i32 = @intCast(opened);
		defer _ = linux.close(fd);

		var buffer: [32 * 1024]u8 = undefined;
		outer: while (true) {
			const read = linux.getdents64(fd, &buffer, buffer.len);
			if (linux.errno(read) != .SUCCESS or read == 0) break;

			var offset: usize = 0;
			while (offset < read) {
				const entry: *align(1) linux.dirent64 = @ptrCast(&buffer[offset]);
				if (entry.reclen == 0) break :outer;
				offset += entry.reclen;

				const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
				if (entry_name.len == 0 or entry_name.len > 255) continue;
				if (entry_name[0] == '.' and !(std.mem.eql(u8, entry_name, ".config") and std.mem.eql(u8, dir.path, self.home))) continue;
				if (skipName(entry_name)) continue;
				if (dir.depth <= 2) {
					self.path.clearRetainingCapacity();
					try self.path.appendSlice(self.allocator, dir.path);
					try self.path.append(self.allocator, '/');
					try self.path.appendSlice(self.allocator, entry_name);
					if (skipPath(self.path.items)) continue;
				}

				var is_dir = entry.type == linux.DT.DIR;
				if (entry.type == linux.DT.UNKNOWN) {
					var st: linux.Statx = undefined;
					if (linux.errno(linux.statx(fd, @ptrCast(&entry.name), linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) continue;
					is_dir = std.posix.S.ISDIR(st.mode);
				}

				try self.children.append(self.allocator, .{ .off = @intCast(self.names.items.len), .len = @intCast(entry_name.len), .dir = is_dir });
				try self.names.appendSlice(self.allocator, entry_name);
			}
		}

		const to: u32 = @intCast(self.children.items.len);
		std.sort.pdq(Child, self.children.items[from..to], self.names.items, struct {
			fn less(names: []const u8, a: Child, b: Child) bool {
				return std.mem.lessThan(u8, names[a.off..][0..a.len], names[b.off..][0..b.len]);
			}
		}.less);
		return .{ .lister = self.index, .from = from, .to = to };
	}
};

fn skipName(entry_name: []const u8) bool {
	for (skipped_names) |junk| if (std.mem.eql(u8, entry_name, junk)) return true;
	return false;
}

fn skipPath(full: []const u8) bool {
	for (guardmod.protected_paths) |prefix| if (std.mem.eql(u8, full, prefix)) return true;
	for (skipped_paths) |prefix| if (std.mem.eql(u8, full, prefix)) return true;
	return false;
}

const batch_dirs = 64;

const Pool = struct {
	io: Io,
	threads: [max_threads]std.Thread = undefined,
	count: usize = 0,
	start: std.Io.Semaphore = .{},
	done: std.Io.Semaphore = .{},
	pass: *Pass = undefined,
	dirs: []const Dir = &.{},
	stop: bool = false,

	fn spawn(self: *Pool, wanted: usize) void {
		while (self.count < wanted) : (self.count += 1) {
			self.threads[self.count] = std.Thread.spawn(.{}, worker, .{ self, self.count }) catch return;
		}
	}

	fn worker(self: *Pool, index: usize) void {
		while (true) {
			self.start.waitUncancelable(self.io);
			if (@atomicLoad(bool, &self.stop, .acquire)) return;
			const pass = self.pass;
			pass.listers[index].run(self.dirs[pass.from..pass.to], pass.results.items, &pass.cursor);
			self.done.post(self.io);
		}
	}

	fn shutdown(self: *Pool) void {
		@atomicStore(bool, &self.stop, true, .release);
		for (0..self.count) |_| self.start.post(self.io);
		for (self.threads[0..self.count]) |thread| thread.join();
		self.count = 0;
	}
};

const Pass = struct {
	pool: *Pool,
	listers: []Lister,
	results: std.ArrayList(Listing) = .empty,
	cursor: std.atomic.Value(usize) = .init(0),
	active: bool = false,
	from: usize = 0,
	to: usize = 0,

	fn start(self: *Pass, allocator: Allocator, dirs: []const Dir, from: usize, to: usize) !void {
		self.from = from;
		self.to = to;
		try self.results.resize(allocator, to - from);
		self.cursor.store(0, .monotonic);
		if (self.pool.count == 0) {
			self.listers[0].run(dirs[from..to], self.results.items, &self.cursor);
			return;
		}
		self.pool.pass = self;
		self.pool.dirs = dirs;
		self.active = true;
		for (0..self.pool.count) |_| self.pool.start.post(self.pool.io);
	}

	fn wait(self: *Pass) !void {
		if (self.active) {
			for (0..self.pool.count) |_| self.pool.done.waitUncancelable(self.pool.io);
			self.active = false;
		}
		for (self.listers) |lister| if (lister.failed) return error.WalkFailed;
	}

	fn reset(self: *Pass) void {
		for (self.listers) |*lister| lister.reset();
	}
};

const Walker = struct {
	allocator: Allocator,
	encoder: *Encoder,
	passes: *[2]Pass,
	blocked: *const std.StringHashMapUnmanaged(void),
	exclude: []const u8 = "",
	ancestors: []const Dir = &.{},

	fn walk(self: *Walker, start: Dir) !void {
		var level: std.ArrayList(Dir) = .empty;
		defer freeDirs(self.allocator, &level);
		try level.append(self.allocator, .{ .path = try self.allocator.dupe(u8, start.path), .id = start.id, .depth = start.depth });
		defer for (self.passes) |*pass| pass.wait() catch {};

		while (level.items.len > 0) {
			var next: std.ArrayList(Dir) = .empty;
			errdefer freeDirs(self.allocator, &next);

			const batches = (level.items.len + batch_dirs - 1) / batch_dirs;
			try self.passes[0].start(self.allocator, level.items, 0, @min(batch_dirs, level.items.len));
			for (0..batches) |b| {
				const pass = &self.passes[b % 2];
				try pass.wait();
				if (b + 1 < batches) try self.passes[(b + 1) % 2].start(self.allocator, level.items, (b + 1) * batch_dirs, @min((b + 2) * batch_dirs, level.items.len));

				for (level.items[pass.from..pass.to], pass.results.items) |*dir, listing| {
					const lister = &pass.listers[listing.lister];
					for (lister.children.items[listing.from..listing.to]) |child| {
						const entry_name = lister.names.items[child.off..][0..child.len];
						if (child.dir and dir.depth <= 2) {
							if (try self.special(dir.*, entry_name, &next)) continue;
						}
						const id = try self.encoder.add(entry_name, dir.id, child.dir);
						if (!child.dir) continue;
						const child_path = try std.mem.concat(self.allocator, u8, &.{ dir.path, "/", entry_name });
						if (self.blocked.contains(child_path)) {
							self.allocator.free(child_path);
							continue;
						}
						try next.append(self.allocator, .{ .path = child_path, .id = id, .depth = dir.depth +| 1 });
					}
					self.allocator.free(dir.path);
					dir.path = &.{};
				}
				pass.reset();
				try self.encoder.posters.ship();
			}

			freeDirs(self.allocator, &level);
			level = next;
		}
	}

	fn special(self: *Walker, dir: Dir, entry_name: []const u8, next: *std.ArrayList(Dir)) !bool {
		var buf: [std.fs.max_path_bytes]u8 = undefined;
		const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir.path, entry_name }) catch return false;
		if (self.exclude.len > 0 and std.mem.eql(u8, full, self.exclude)) return true;
		for (self.ancestors) |ancestor| {
			if (!std.mem.eql(u8, full, ancestor.path)) continue;
			try next.append(self.allocator, .{ .path = try self.allocator.dupe(u8, full), .id = ancestor.id, .depth = dir.depth +| 1 });
			return true;
		}
		return false;
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
	var header: Header = .{ .built_ms = built_ms, .names_at = @sizeOf(Header) };
	try w.writeAll(std.mem.asBytes(&header));

	const thread_count = @min(std.Thread.getCpuCount() catch 1, max_threads);
	var pair: [2]*Poster = undefined;
	var made: usize = 0;
	defer for (pair[0..made]) |poster| {
		poster.deinit();
		allocator.destroy(poster);
	};
	while (made < 2) : (made += 1) {
		pair[made] = try allocator.create(Poster);
		pair[made].* = .{ .allocator = allocator, .store = try Store.init(allocator), .tri = made == 0 };
	}
	var posters: Posters = .{ .io = io, .allocator = allocator, .posters = pair };
	posters.spawn();
	defer posters.deinit();

	var encoder: Encoder = .{ .allocator = allocator, .w = w, .posters = &posters };
	defer encoder.starts.deinit(allocator);
	var listers: [2][max_threads]Lister = undefined;
	var pool: Pool = .{ .io = io };
	pool.spawn(thread_count);
	defer pool.shutdown();
	var passes: [2]Pass = undefined;
	for (&listers, &passes) |*set, *pass| {
		for (set[0..thread_count], 0..) |*lister, i| lister.* = .{ .allocator = allocator, .index = @intCast(i), .home = home_path };
		pass.* = .{ .pool = &pool, .listers = set[0..@max(1, pool.count)] };
	}
	defer for (&listers, &passes) |*set, *pass| {
		for (set[0..thread_count]) |*lister| lister.deinit();
		pass.results.deinit(allocator);
	};

	_ = try encoder.add(root_name, none, true);
	var blocked = try blockedMounts(io, allocator, root_name, home_path);
	defer {
		var keys = blocked.keyIterator();
		while (keys.next()) |key| allocator.free(key.*);
		blocked.deinit(allocator);
	}
	var walker: Walker = .{ .allocator = allocator, .encoder = &encoder, .passes = &passes, .blocked = &blocked };

	var ancestors: std.ArrayList(Dir) = .empty;
	defer {
		for (ancestors.items) |dir| allocator.free(dir.path);
		ancestors.deinit(allocator);
	}

	if (home_path.len > root_name.len and within(home_path, root_name) and !hidden(home_path[root_name.len..])) {
		var parent: u32 = 0;
		var parts = std.mem.tokenizeScalar(u8, home_path[root_name.len..], '/');
		while (parts.next()) |part| {
			const id = try encoder.add(part, parent, true);
			const end = @intFromPtr(part.ptr) - @intFromPtr(home_path.ptr) + part.len;
			try ancestors.append(allocator, .{ .path = try allocator.dupe(u8, home_path[0..end]), .id = id, .depth = 0 });
			parent = id;
		}
		const top = ancestors.items[ancestors.items.len - 1];
		try walker.walk(.{ .path = top.path, .id = top.id, .depth = 3 });
		walker.exclude = home_path;
		walker.ancestors = ancestors.items[0 .. ancestors.items.len - 1];
	}
	try walker.walk(.{ .path = @constCast(root_name), .id = 0, .depth = 0 });
	try encoder.finish();

	header.count = encoder.count;
	header.blocks = @intCast(encoder.starts.items.len - 1);
	header.names_len = encoder.names_len;
	header.post_at = header.names_at + header.names_len;

	var keys: std.ArrayList(Key) = .empty;
	defer keys.deinit(allocator);
	header.post_len = try writeStore(allocator, &pair[1].store, w, &keys, try writeStore(allocator, &pair[0].store, w, &keys, 0));
	header.keys = @intCast(keys.items.len);

	const pad = (4 - (header.post_at + header.post_len) % 4) % 4;
	try w.splatByteAll(0, pad);
	header.starts_at = header.post_at + header.post_len + pad;
	try w.writeAll(std.mem.sliceAsBytes(encoder.starts.items));
	header.keys_at = header.starts_at + encoder.starts.items.len * 4;
	try w.writeAll(std.mem.sliceAsBytes(keys.items));
	try w.flush();

	if (linux.errno(linux.pwrite(file.handle, std.mem.asBytes(&header), @sizeOf(Header), 0)) != .SUCCESS) return error.WriteFailed;
	file.close(io);
	closed = true;
	try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), out_path, io);
}

const Mount = struct {
	point: []u8,
	source: []const u8,
};

fn blockedMounts(io: Io, allocator: Allocator, root: []const u8, home: []const u8) !std.StringHashMapUnmanaged(void) {
	var blocked: std.StringHashMapUnmanaged(void) = .empty;
	errdefer blocked.deinit(allocator);
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
		var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
		var index: usize = 0;
		var point: []const u8 = "";
		while (head.next()) |field| : (index += 1) if (index == 4) {
			point = field;
		};
		_ = tail.next();
		const source = tail.next() orelse continue;
		if (point.len == 0) continue;
		try mounts.append(allocator, .{ .point = try guardmod.unescape(allocator, point), .source = source });
	}

	const keep_root = sourceOf(mounts.items, root);
	const keep_home = sourceOf(mounts.items, home);
	for (mounts.items) |mount| {
		if (std.mem.eql(u8, mount.source, keep_root) or std.mem.eql(u8, mount.source, keep_home)) continue;
		if (!within(mount.point, root) or std.mem.eql(u8, mount.point, root)) continue;
		if (blocked.contains(mount.point)) continue;
		try blocked.put(allocator, try allocator.dupe(u8, mount.point), {});
	}
	return blocked;
}

fn sourceOf(mounts: []const Mount, path: []const u8) []const u8 {
	var best: ?Mount = null;
	for (mounts) |mount| {
		if (!within(path, mount.point)) continue;
		if (best == null or mount.point.len >= best.?.point.len) best = mount;
	}
	return if (best) |mount| mount.source else "";
}

fn within(path: []const u8, root: []const u8) bool {
	if (root.len == 0 or std.mem.eql(u8, root, "/")) return path.len > 0 and path[0] == '/';
	return guardmod.hasPrefix(path, root);
}

fn hidden(rel: []const u8) bool {
	var parts = std.mem.tokenizeScalar(u8, rel, '/');
	while (parts.next()) |part| if (part[0] == '.') return true;
	return false;
}

const recent_cap = 512;
const watch_cap = 2048;
const watch_depth = 2;

const Fresh = struct {
	path: []u8,
	at: i64,
};

const Watched = struct {
	path: []u8,
	depth: u8,
};

pub const Recent = struct {
	allocator: Allocator,
	io: Io,
	home: []u8,
	fd: i32 = -1,
	mutex: std.Io.Mutex = .init,
	paths: std.ArrayList(Fresh) = .empty,
	dirs: std.AutoHashMapUnmanaged(i32, Watched) = .empty,

	pub fn create(allocator: Allocator, io: Io, home: []const u8) !*Recent {
		const self = try allocator.create(Recent);
		errdefer allocator.destroy(self);
		self.* = .{ .allocator = allocator, .io = io, .home = try allocator.dupe(u8, std.mem.trimEnd(u8, home, "/")) };
		return self;
	}

	pub fn start(self: *Recent) !void {
		const fd = linux.inotify_init1(linux.IN.CLOEXEC);
		if (linux.errno(fd) != .SUCCESS) return error.WatchInit;
		self.fd = @intCast(fd);
		self.watchTree(self.home, 0);
		const thread = try std.Thread.spawn(.{}, loop, .{self});
		thread.detach();
	}

	fn watchTree(self: *Recent, path: []const u8, depth: u8) void {
		if (self.dirs.count() >= watch_cap) return;
		const z = self.allocator.dupeSentinel(u8, path, 0) catch return;
		defer self.allocator.free(z);
		const wd = linux.inotify_add_watch(self.fd, z, linux.IN.CREATE | linux.IN.MOVED_TO | linux.IN.ONLYDIR);
		if (linux.errno(wd) != .SUCCESS) return;
		const owned = self.allocator.dupe(u8, path) catch return;
		self.mutex.lockUncancelable(self.io);
		const old = self.dirs.fetchPut(self.allocator, @intCast(wd), .{ .path = owned, .depth = depth }) catch null;
		self.mutex.unlock(self.io);
		if (old) |entry| self.allocator.free(entry.value.path);
		if (depth >= watch_depth) return;

		const opened = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
		if (linux.errno(opened) != .SUCCESS) return;
		const fd: i32 = @intCast(opened);
		defer _ = linux.close(fd);
		var buffer: [16 * 1024]u8 = undefined;
		while (true) {
			const read = linux.getdents64(fd, &buffer, buffer.len);
			if (linux.errno(read) != .SUCCESS or read == 0) return;
			var offset: usize = 0;
			while (offset < read) {
				const entry: *align(1) linux.dirent64 = @ptrCast(&buffer[offset]);
				if (entry.reclen == 0) return;
				offset += entry.reclen;
				if (entry.type != linux.DT.DIR) continue;
				const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
				if (name.len == 0 or name[0] == '.' or skipName(name)) continue;
				var child_buf: [std.fs.max_path_bytes]u8 = undefined;
				const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
				self.watchTree(child, depth + 1);
			}
		}
	}

	fn loop(self: *Recent) void {
		var buffer: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
		while (true) {
			const read = linux.read(self.fd, &buffer, buffer.len);
			if (linux.errno(read) == .INTR) continue;
			if (linux.errno(read) != .SUCCESS or read == 0) return;
			var offset: usize = 0;
			while (offset + @sizeOf(linux.inotify_event) <= read) {
				const event: *align(1) const linux.inotify_event = @ptrCast(&buffer[offset]);
				const name_start = offset + @sizeOf(linux.inotify_event);
				offset = name_start + event.len;
				if (event.mask & linux.IN.IGNORED != 0) {
					self.forget(event.wd);
					continue;
				}
				const name = std.mem.sliceTo(buffer[name_start..@min(offset, read)], 0);
				if (name.len == 0 or name[0] == '.' or skipName(name)) continue;
				self.note(event.wd, name, event.mask & linux.IN.ISDIR != 0);
			}
		}
	}

	fn forget(self: *Recent, wd: i32) void {
		self.mutex.lockUncancelable(self.io);
		const old = self.dirs.fetchRemove(wd);
		self.mutex.unlock(self.io);
		if (old) |entry| self.allocator.free(entry.value.path);
	}

	fn note(self: *Recent, wd: i32, name: []const u8, dir: bool) void {
		self.mutex.lockUncancelable(self.io);
		const parent = self.dirs.get(wd) orelse {
			self.mutex.unlock(self.io);
			return;
		};
		const full = std.mem.concat(self.allocator, u8, &.{ parent.path, "/", name }) catch {
			self.mutex.unlock(self.io);
			return;
		};
		if (self.paths.items.len >= recent_cap) self.allocator.free(self.paths.orderedRemove(0).path);
		self.paths.append(self.allocator, .{ .path = full, .at = std.Io.Clock.real.now(self.io).toMilliseconds() }) catch self.allocator.free(full);
		const depth = parent.depth;
		self.mutex.unlock(self.io);
		if (dir and depth < watch_depth) {
			var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
			if (copy_buf.len < full.len) return;
			@memcpy(copy_buf[0..full.len], full);
			self.watchTree(copy_buf[0..full.len], depth + 1);
		}
	}

	pub fn search(self: *Recent, arena: Allocator, query: []const u8, out: *std.ArrayList([]const u8)) !void {
		if (query.len == 0 or query.len > 255) return;
		var needle_buf: [256]u8 = undefined;
		const needle = fold(&needle_buf, query);
		const ascii = isAscii(needle);
		var folded: [256]u8 = undefined;
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		var at = self.paths.items.len;
		while (at > 0) {
			at -= 1;
			const path = self.paths.items[at].path;
			if (!matches(std.fs.path.basename(path), needle, ascii, &folded)) continue;
			try out.append(arena, try arena.dupe(u8, path));
		}
	}

	pub fn prune(self: *Recent, before: i64) void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		var at: usize = 0;
		while (at < self.paths.items.len) {
			if (self.paths.items[at].at >= before) {
				at += 1;
				continue;
			}
			self.allocator.free(self.paths.orderedRemove(at).path);
		}
	}
};

pub fn command(io: Io, args: []const []const u8) !void {
	if (args.len < 5) return error.Usage;
	_ = linux.syscall3(.setpriority, 0, 0, 19);
	try build(io, std.heap.smp_allocator, args[2], args[3], args[4], std.Io.Clock.real.now(io).toMilliseconds());
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

pub fn matches(name: []const u8, needle: []const u8, ascii: bool, scratch: *[256]u8) bool {
	if (ascii) return std.ascii.findIgnoreCase(name, needle) != null;
	return std.mem.indexOf(u8, fold(scratch, name), needle) != null;
}

pub fn isAscii(text: []const u8) bool {
	for (text) |c| if (c >= 0x80) return false;
	return true;
}

pub fn fold(dst: *[256]u8, src: []const u8) []const u8 {
	const len = @min(src.len, dst.len);
	var i: usize = 0;
	while (i < len) {
		const c = src[i];
		if (c >= 0xC2 and c <= 0xDF and i + 1 < len and src[i + 1] & 0xC0 == 0x80) {
			const cp = foldCodepoint(@as(u16, c & 0x1f) << 6 | (src[i + 1] & 0x3f));
			dst[i] = 0xC0 | @as(u8, @intCast(cp >> 6));
			dst[i + 1] = 0x80 | @as(u8, @intCast(cp & 0x3f));
			i += 2;
			continue;
		}
		dst[i] = std.ascii.toLower(c);
		i += 1;
	}
	return dst[0..len];
}

fn foldCodepoint(cp: u16) u16 {
	return switch (cp) {
		0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
		0x100...0x12F, 0x132...0x137, 0x14A...0x177 => cp | 1,
		0x139...0x148, 0x179...0x17E => if (cp & 1 == 1) cp + 1 else cp,
		0x178 => 0xFF,
		0x391...0x3A1, 0x3A3...0x3AB => cp + 0x20,
		0x400...0x40F => cp + 0x50,
		0x410...0x42F => cp + 0x20,
		0x460...0x481, 0x48A...0x4BF => cp | 1,
		else => cp,
	};
}

fn lower(c: u8) u32 {
	return std.ascii.toLower(c);
}

const symbols = blk: {
	var table: [256]u8 = undefined;
	for (&table, 0..) |*slot, c| {
		const low = std.ascii.toLower(c);
		slot.* = switch (low) {
			'a'...'z' => low - 'a',
			'0'...'9' => 26 + low - '0',
			'.' => 36,
			'-' => 37,
			'_' => 38,
			' ' => 39,
			0...31 => 40,
			33...44, 47 => 41 + (low % 4),
			58...64, 91...94, 96, 123...127 => 45 + (low % 3),
			else => 48 + (low & 15),
		};
	}
	break :blk table;
};

fn triOf(bytes: *const [3]u8) u32 {
	return @as(u32, symbols[bytes[0]]) << 12 | @as(u32, symbols[bytes[1]]) << 6 | symbols[bytes[2]];
}

fn zigzag(value: i64) u64 {
	return @bitCast((value << 1) ^ (value >> 63));
}

fn unzigzag(value: u64) i64 {
	return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @bitCast(value & 1));
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

	const index_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{root});
	defer allocator.free(index_path);
	defer std.Io.Dir.cwd().deleteFile(io, index_path) catch {};
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

	const docs = try std.fmt.allocPrint(allocator, "{s}/Docs", .{root});
	defer allocator.free(docs);
	try build(io, allocator, root, docs, index_path, 43);
	var homed = try load(io, index_path);
	defer homed.deinit();
	try std.testing.expectEqual(index.count, homed.count);
	try std.testing.expectEqual(@as(usize, 1), homed.search("docs", &hits));
	try std.testing.expectEqual(@as(usize, 2), homed.search("report", &hits));
	try std.testing.expectEqualStrings("old-report.txt", homed.item(hits[0], &buf).name);
	try std.testing.expectEqualStrings(full, homed.path(&buffer, hits[0]));
}

test "fold lowers ascii, latin, greek and cyrillic in place" {
	var buf: [256]u8 = undefined;
	try std.testing.expectEqualStrings("übersicht ñandú", fold(&buf, "ÜBERSICHT ÑANDÚ"));
	try std.testing.expectEqualStrings("ελλαδα привет", fold(&buf, "ΕΛΛΑΔΑ ПРИВЕТ"));
	try std.testing.expectEqualStrings("łódź ÿ", fold(&buf, "ŁÓDŹ Ÿ"));
	try std.testing.expectEqualStrings("日本語", fold(&buf, "日本語"));
}

test "mounts on another device are blocked, the root and home devices are kept" {
	const points = [_][]u8{ @constCast("/"), @constCast("/home"), @constCast("/mnt/usb"), @constCast("/home/me/nas") };
	const mounts = [_]Mount{
		.{ .point = points[0], .source = "/dev/sda2" },
		.{ .point = points[1], .source = "/dev/sda2" },
		.{ .point = points[2], .source = "/dev/sdb1" },
		.{ .point = points[3], .source = "nas:/share" },
	};
	try std.testing.expectEqualStrings("/dev/sda2", sourceOf(&mounts, "/home/me"));
	try std.testing.expectEqualStrings("/dev/sdb1", sourceOf(&mounts, "/mnt/usb/photos"));
	try std.testing.expect(within("/mnt", "/"));
	try std.testing.expect(within("/home/me", "/home"));
	try std.testing.expect(!within("/homes", "/home"));
}

test "recent files show up from inotify before the next rebuild" {
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
	defer allocator.free(base);
	const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
	defer allocator.free(root);
	const sub = try std.fmt.allocPrint(allocator, "{s}/Downloads", .{root});
	defer allocator.free(sub);
	try std.Io.Dir.cwd().createDirPath(io, sub);

	var recent: Recent = .{ .allocator = allocator, .io = io, .home = try allocator.dupe(u8, root) };
	defer {
		_ = linux.close(recent.fd);
		var it = recent.dirs.valueIterator();
		while (it.next()) |dir| allocator.free(dir.path);
		recent.dirs.deinit(allocator);
		for (recent.paths.items) |fresh| allocator.free(fresh.path);
		recent.paths.deinit(allocator);
		allocator.free(recent.home);
	}
	const fd = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
	recent.fd = @intCast(fd);
	recent.watchTree(recent.home, 0);
	try std.testing.expectEqual(@as(u32, 2), recent.dirs.count());

	const file = try std.fmt.allocPrint(allocator, "{s}/Fresh-Invoice.pdf", .{sub});
	defer allocator.free(file);
	var created = try std.Io.Dir.cwd().createFile(io, file, .{});
	created.close(io);

	var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
	const read = linux.read(recent.fd, &buffer, buffer.len);
	try std.testing.expect(linux.errno(read) == .SUCCESS);
	const event: *align(1) const linux.inotify_event = @ptrCast(&buffer[0]);
	recent.note(event.wd, std.mem.sliceTo(buffer[@sizeOf(linux.inotify_event)..read], 0), false);

	var arena = std.heap.ArenaAllocator.init(allocator);
	defer arena.deinit();
	var out: std.ArrayList([]const u8) = .empty;
	try recent.search(arena.allocator(), "INVOICE", &out);
	try std.testing.expectEqual(@as(usize, 1), out.items.len);
	try std.testing.expectEqualStrings(file, out.items[0]);

	recent.prune(std.math.maxInt(i64));
	out.clearRetainingCapacity();
	try recent.search(arena.allocator(), "invoice", &out);
	try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
