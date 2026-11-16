const std = @import("std");

pub const magic = "YUDFILE\x00";
pub const version: u32 = 6;
pub const dir_bit: u32 = 1 << 31;
pub const none: u32 = dir_bit - 1;
pub const block_size = 64;
pub const coarse = 16;
pub const tag_bi: u32 = 1 << 24;
pub const tag_uni: u32 = 2 << 24;
const max_lists = 8;

pub const Header = extern struct {
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
	dirs_at: u64 = 0,
	dirs: u64 = 0,
	scope: u64 = 0,
};

pub const DirRecord = extern struct {
	id: u32,
	first: u32,
	count: u32,
	partial: u32 = 0,
	mtime: i64,
};

pub const Key = extern struct {
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
		const tail = readVarint(self.bytes, &self.at);
		self.parent = @intCast(@as(i64, self.parent) + unzigzag(tail >> 1));
		return .{ .name = buf[0 .. shared + rest], .parent = self.parent, .dir = tail & 1 != 0 };
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
	dirs: []const DirRecord,
	count: u32,
	built_ms: i64,
	scope: u64,

	pub fn deinit(self: *Index) void {
		std.posix.munmap(self.mapped);
	}

	fn cursor(self: *const Index, block: usize) Cursor {
		return .{ .bytes = self.names[self.starts[block]..self.starts[block + 1]] };
	}

	pub fn item(self: *const Index, id: u32, buf: *[256]u8) Item {
		var walk = self.cursor(id / block_size);
		var at = id - id % block_size;
		while (walk.next(buf)) |entry| : (at += 1) if (at == id) return entry;
		return .{ .name = "", .parent = none, .dir = false };
	}

	pub fn children(self: *const Index, first: u32) Range {
		var range: Range = .{ .index = self, .block = first / block_size, .cursor = self.cursor(first / block_size) };
		var buf: [256]u8 = undefined;
		for (0..first % block_size) |_| _ = range.cursor.next(&buf);
		return range;
	}

	pub fn dirOf(self: *const Index, id: u32) ?DirRecord {
		const at = std.sort.lowerBound(DirRecord, self.dirs, id, struct {
			fn order(target: u32, record: DirRecord) std.math.Order {
				return std.math.order(target, record.id);
			}
		}.order);
		return if (at < self.dirs.len and self.dirs[at].id == id) self.dirs[at] else null;
	}

	pub fn find(self: *const Index, rel: []const u8) u32 {
		var id: u32 = 0;
		var parts = std.mem.tokenizeScalar(u8, rel, '/');
		var buf: [256]u8 = undefined;
		next: while (parts.next()) |part| {
			const record = self.dirOf(id) orelse return none;
			var range = self.children(record.first);
			for (0..record.count) |at| {
				if (!std.mem.eql(u8, range.next(&buf).?.name, part)) continue;
				id = record.first + @as(u32, @intCast(at));
				continue :next;
			}
			return none;
		}
		return id;
	}

	pub fn path(self: *const Index, buffer: []u8, id: u32) []const u8 {
		var buf: [256]u8 = undefined;
		var end = buffer.len;
		var at = id;
		while (true) {
			const entry = self.item(at, &buf);
			const slash: usize = @intFromBool(entry.parent != none);
			if (end < entry.name.len + slash) return "";
			end -= entry.name.len;
			@memcpy(buffer[end .. end + entry.name.len], entry.name);
			if (entry.parent == none) break;
			end -= 1;
			buffer[end] = '/';
			at = entry.parent;
		}
		return if (end == buffer.len) "/" else buffer[end..];
	}

	pub fn search(self: *const Index, query: []const u8, out: []u32) usize {
		if (query.len == 0 or query.len > 255 or out.len == 0) return 0;
		var needle_buf: [256]u8 = undefined;
		var folded: [256]u8 = undefined;
		var buf: [256]u8 = undefined;
		const needle = fold(&needle_buf, query);
		const ascii = isAscii(needle);
		var lists: [max_lists]Postings = undefined;
		const used = self.gather(needle, &lists);
		if (used == 0) return 0;

		const span: usize = if (needle.len < 3) coarse else 1;
		var found: usize = 0;
		while (lists[0].next()) |first| {
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
			for (block * span..@min((block + 1) * span, self.starts.len - 1)) |at| {
				var walk = self.cursor(at);
				var id: u32 = @intCast(at * block_size);
				while (walk.next(&buf)) |entry| : (id += 1) {
					if (id == 0 or !matches(entry.name, needle, ascii, &folded)) continue;
					out[found] = id;
					found += 1;
					if (found == out.len) return found;
				}
			}
		}
		return found;
	}

	fn gather(self: *const Index, needle: []const u8, lists: *[max_lists]Postings) usize {
		var keys: [256]Key = undefined;
		var count: usize = 0;
		if (needle.len < 3) {
			const gram = if (needle.len == 1) tag_uni | @as(u32, needle[0]) else tag_bi | @as(u32, needle[0]) << 8 | needle[1];
			keys[0] = self.lookup(gram) orelse return 0;
			count = 1;
		}
		var i: usize = 0;
		while (needle.len >= 3 and i + 3 <= needle.len) : (i += 1) {
			keys[count] = self.lookup(triOf(needle[i..][0..3])) orelse return 0;
			count += 1;
		}
		std.sort.pdq(Key, keys[0..count], {}, struct {
			fn less(_: void, x: Key, y: Key) bool {
				return x.count < y.count or (x.count == y.count and x.off < y.off);
			}
		}.less);
		var used: usize = 0;
		for (keys[0..count]) |key| {
			if (used == max_lists) break;
			if (used > 0 and lists[used - 1].at == key.off) continue;
			lists[used] = .{ .bytes = self.post, .at = key.off, .left = key.count };
			used += 1;
		}
		return used;
	}

	fn lookup(self: *const Index, gram: u32) ?Key {
		const at = std.sort.lowerBound(Key, self.keys, gram, struct {
			fn order(target: u32, key: Key) std.math.Order {
				return std.math.order(target, key.gram);
			}
		}.order);
		return if (at < self.keys.len and self.keys[at].gram == gram) self.keys[at] else null;
	}
};

pub const Range = struct {
	index: *const Index,
	block: usize,
	cursor: Cursor,

	pub fn next(self: *Range, buf: *[256]u8) ?Item {
		while (true) {
			if (self.cursor.next(buf)) |entry| return entry;
			self.block += 1;
			if (self.block + 1 >= self.index.starts.len) return null;
			self.cursor = self.index.cursor(self.block);
		}
	}
};

pub fn load(io: std.Io, file_path: []const u8) !Index {
	var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
	defer file.close(io);
	const stat = try file.stat(io);
	if (stat.size < @sizeOf(Header)) return error.BadIndex;
	const mapped = try std.posix.mmap(null, @intCast(stat.size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
	errdefer std.posix.munmap(mapped);

	const header: *const Header = @ptrCast(@alignCast(mapped.ptr));
	if (!std.mem.eql(u8, &header.magic, magic) or header.version != version) return error.BadIndex;
	if (header.names_at + header.names_len > mapped.len or header.post_at + header.post_len > mapped.len) return error.BadIndex;
	if (header.starts_at % 4 != 0 or header.starts_at + (@as(u64, header.blocks) + 1) * 4 > mapped.len) return error.BadIndex;
	if (header.keys_at + @as(u64, header.keys) * @sizeOf(Key) > mapped.len) return error.BadIndex;
	if (header.dirs_at % 8 != 0 or header.dirs_at + header.dirs * @sizeOf(DirRecord) != mapped.len) return error.BadIndex;

	return .{
		.mapped = mapped,
		.starts = @as([*]const u32, @ptrCast(@alignCast(mapped.ptr + header.starts_at)))[0 .. header.blocks + 1],
		.keys = @as([*]const Key, @ptrCast(@alignCast(mapped.ptr + header.keys_at)))[0..header.keys],
		.names = mapped[header.names_at..][0..header.names_len],
		.post = mapped[header.post_at..][0..header.post_len],
		.dirs = @as([*]const DirRecord, @ptrCast(@alignCast(mapped.ptr + header.dirs_at)))[0..header.dirs],
		.count = header.count,
		.built_ms = header.built_ms,
		.scope = header.scope,
	};
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
	while (i < len) : (i += 1) {
		const c = src[i];
		if (c < 0xC2 or c > 0xDF or i + 1 >= len or src[i + 1] & 0xC0 != 0x80) {
			dst[i] = std.ascii.toLower(c);
			continue;
		}
		const cp = foldCodepoint(@as(u16, c & 0x1f) << 6 | (src[i + 1] & 0x3f));
		dst[i] = 0xC0 | @as(u8, @intCast(cp >> 6));
		dst[i + 1] = 0x80 | @as(u8, @intCast(cp & 0x3f));
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

pub fn triOf(bytes: *const [3]u8) u32 {
	return @as(u32, symbols[bytes[0]]) << 12 | @as(u32, symbols[bytes[1]]) << 6 | symbols[bytes[2]];
}

pub fn zigzag(value: i64) u64 {
	return @bitCast((value << 1) ^ (value >> 63));
}

fn unzigzag(value: u64) i64 {
	return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @bitCast(value & 1));
}

pub fn encodeVarint(buf: *[10]u8, value: u64) []const u8 {
	var v = value;
	var len: usize = 0;
	while (v >= 0x80) : (v >>= 7) {
		buf[len] = @as(u8, @truncate(v)) | 0x80;
		len += 1;
	}
	buf[len] = @truncate(v);
	return buf[0 .. len + 1];
}

fn readVarint(bytes: []const u8, at: *usize) u64 {
	var value: u64 = 0;
	var shift: u6 = 0;
	while (true) : (shift +|= 7) {
		const byte = bytes[at.*];
		at.* += 1;
		value |= @as(u64, byte & 0x7f) << shift;
		if (byte & 0x80 == 0) return value;
	}
}

test "fold lowers ascii, latin, greek and cyrillic in place" {
	var buf: [256]u8 = undefined;
	try std.testing.expectEqualStrings("übersicht ñandú", fold(&buf, "ÜBERSICHT ÑANDÚ"));
	try std.testing.expectEqualStrings("ελλαδα привет", fold(&buf, "ΕΛΛΑΔΑ ПРИВЕТ"));
	try std.testing.expectEqualStrings("łódź ÿ", fold(&buf, "ŁÓDŹ Ÿ"));
	try std.testing.expectEqualStrings("日本語", fold(&buf, "日本語"));
}
