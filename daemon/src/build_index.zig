const std = @import("std");
const http = @import("primitives/http.zig");
const json = @import("primitives/json.zig");
const proc = @import("primitives/proc.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const langs = [_][]const u8{ "en", "de", "es", "pt", "ja", "zh", "fr", "it", "ko", "ru", "nl", "pl", "tr", "id", "vi", "uk", "hi", "th", "ar" };
const kao_langs = [_][]const u8{ "en", "de", "es", "pt", "ja", "zh" };
const cldr_tag = "release-49";
const emoji_url = "https://unicode.org/Public/emoji/16.0/emoji-test.txt";
const kao_url = "https://registry.npmjs.org/kaomoji-dataset/-/kaomoji-dataset-1.0.6.tgz";
const Entry = struct {
	kind: u8,
	text: []const u8,
	name: []const u8,
	keywords: std.StringHashMapUnmanaged(void) = .empty,
};
const Ref = struct {
	start: u32,
	len: u32,
};
const Parser = struct {
	allocator: Allocator,
	io: Io,
	client: http.Client,
	cache: []const u8,
	fn init(allocator: Allocator, io: Io, cache: []const u8) Parser {
		return .{ .allocator = allocator, .io = io, .client = http.Client.init(allocator, io), .cache = cache };
	}
	fn fetch(self: *Parser, url: []const u8, path: []const u8) ![]const u8 {
		if (proc.exists(self.io, path)) return path;
		const reply = try self.client.get(self.allocator, url, null, &.{});
		defer reply.deinit(self.allocator);
		if (!reply.ok()) return error.FetchFailed;
		try proc.writeFileAtomic(self.io, self.allocator, path, reply.body);
		return path;
	}
	fn fetchCldr(self: *Parser, language: []const u8) ![]const u8 {
		const url = try std.fmt.allocPrint(self.allocator, "https://raw.githubusercontent.com/unicode-org/cldr/{s}/common/annotations/{s}.xml", .{ cldr_tag, language });
		const path = try std.fmt.allocPrint(self.allocator, "{s}/cldr/{s}/{s}.xml", .{ self.cache, cldr_tag, language });
		return self.fetch(url, path);
	}
};
const Annotations = struct {
	name: []const u8 = "",
	keywords: [][]const u8 = &.{},
};
fn unescape(allocator: Allocator, text: []const u8, out: *std.ArrayList(u8)) !void {
	var index: usize = 0;
	while (index < text.len) {
		if (text[index] != '&') {
			try out.append(allocator, text[index]);
			index += 1;
			continue;
		}
		const end = std.mem.indexOfScalarPos(u8, text, index, ';') orelse {
			try out.append(allocator, text[index]);
			index += 1;
			continue;
		};
		const entity = text[index + 1 .. end];
		var decoded: ?u21 = null;
		if (std.mem.eql(u8, entity, "amp")) decoded = '&'
		else if (std.mem.eql(u8, entity, "lt")) decoded = '<'
		else if (std.mem.eql(u8, entity, "gt")) decoded = '>'
		else if (std.mem.eql(u8, entity, "quot")) decoded = '"'
		else if (std.mem.eql(u8, entity, "apos")) decoded = '\''
		else if (entity.len > 1 and entity[0] == '#') {
			const number = if (entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X'))
				std.fmt.parseInt(u21, entity[2..], 16) catch null
			else
				std.fmt.parseInt(u21, entity[1..], 10) catch null;
			decoded = number;
		}
		if (decoded) |codepoint| {
			var buffer: [4]u8 = undefined;
			const size = std.unicode.utf8Encode(codepoint, &buffer) catch 0;
			try out.appendSlice(allocator, buffer[0..size]);
			index = end + 1;
		} else {
			try out.append(allocator, text[index]);
			index += 1;
		}
	}
}
fn loadLanguage(parser: *Parser, allocator: Allocator, language: []const u8) !std.StringHashMapUnmanaged(Annotations) {
	const path = try parser.fetchCldr(language);
	const body = try proc.readFile(parser.io, allocator, path);
	var map: std.StringHashMapUnmanaged(Annotations) = .empty;
	var scratch: std.ArrayList(u8) = .empty;
	defer scratch.deinit(allocator);
	var lines = std.mem.splitScalar(u8, body, '\n');
	while (lines.next()) |raw_line| {
		const line = std.mem.trim(u8, raw_line, " \t\r");
		if (!std.mem.startsWith(u8, line, "<annotation cp=\"")) continue;
		const cp_end = std.mem.indexOfScalarPos(u8, line, "<annotation cp=\"".len, '"') orelse continue;
		const cp = line["<annotation cp=\"".len..cp_end];
		const tag_end = std.mem.indexOfPos(u8, line, cp_end, "\">") orelse continue;
		const rest = line[tag_end + 2 ..];
		const text_end = std.mem.indexOf(u8, rest, "</annotation>") orelse continue;
		const tts = std.mem.indexOf(u8, line[cp_end..tag_end + 1], "type=\"tts\"") != null;
		scratch.clearRetainingCapacity();
		try unescape(allocator, rest[0..text_end], &scratch);
		const text = try allocator.dupe(u8, scratch.items);
		const entry = try map.getOrPut(allocator, cp);
		if (!entry.found_existing) entry.value_ptr.* = .{};
		if (tts) {
			entry.value_ptr.name = text;
		} else {
			var keywords: std.ArrayList([]const u8) = .empty;
			var words = std.mem.splitSequence(u8, text, " | ");
			while (words.next()) |word| {
				if (word.len > 0) try keywords.append(allocator, word);
			}
			entry.value_ptr.keywords = try keywords.toOwnedSlice(allocator);
		}
	}
	return map;
}
fn uppercaseFirst(name: []const u8) []const u8 {
	if (name.len == 0) return name;
	const upper = std.ascii.toUpper(name[0]);
	if (upper == name[0]) return name;
	const copy = std.heap.smp_allocator.dupe(u8, name) catch return name;
	copy[0] = upper;
	return copy;
}
fn fileref(allocator: Allocator, pool: *std.ArrayList(u8), offsets: *std.StringHashMapUnmanaged(Ref), text: []const u8) !Ref {
	if (offsets.get(text)) |ref| return ref;
	const start: u32 = @intCast(pool.items.len);
	try pool.appendSlice(allocator, text);
	const ref: Ref = .{ .start = start, .len = @intCast(text.len) };
	try offsets.put(allocator, text, ref);
	return ref;
}
fn gzipDecompress(allocator: Allocator, body: []const u8) ![]u8 {
	var input = std.Io.Reader.fixed(body);
	var window: [std.compress.flate.max_window_len]u8 = undefined;
	var decompress = std.compress.flate.Decompress.init(&input, .gzip, &window);
	return decompress.reader.allocRemaining(allocator, .unlimited);
}
fn gzipCompress(allocator: Allocator, body: []const u8) ![]u8 {
	var window: [std.compress.flate.max_window_len]u8 = undefined;
	var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64 * 1024);
	var compress = try std.compress.flate.Compress.init(&out.writer, &window, .gzip, std.compress.flate.Compress.Options.best);
	try compress.writer.writeAll(body);
	try compress.finish();
	return out.toOwnedSlice();
}
pub fn main() !void {
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();
	var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
	const io = threaded.io();
	const args = try proc.args(io, allocator);
	const repo = proc.repo(io, allocator);
	const cache = try std.fmt.allocPrint(allocator, "{s}/cache/.shell/launcher-index-src", .{repo});
	const out = if (args.len > 1) args[1] else try std.fmt.allocPrint(allocator, "{s}/build/assets/launcher-index.bin.gz", .{repo});
	var force = false;
	for (args[2..]) |arg| {
		if (std.mem.eql(u8, arg, "--force")) force = true;
	}
	if (proc.exists(io, out) and !force) return;
	var parser = Parser.init(allocator, io, cache);
	var annotations = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Annotations)){};
	for (langs) |language| {
		const map = try loadLanguage(&parser, allocator, language);
		try annotations.put(allocator, language, map);
	}
	const english = annotations.get("en").?;
	var seen = std.StringHashMapUnmanaged(void){};
	var entries: std.ArrayList(Entry) = .empty;
	const emoji_path = try parser.fetch(emoji_url, try std.fmt.allocPrint(allocator, "{s}/emoji-test-16.0.txt", .{cache}));
	const emoji_body = try proc.readFile(io, allocator, emoji_path);
	var emoji_lines = std.mem.splitScalar(u8, emoji_body, '\n');
	while (emoji_lines.next()) |raw_line| {
		const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
		const line = std.mem.trim(u8, raw_line[0..comment], " \t\r");
		if (std.mem.indexOf(u8, line, "; fully-qualified") == null) continue;
		const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
		const codepoints_text = std.mem.trim(u8, line[0..semi], " \t");
		var codepoints: [16]u21 = undefined;
		var count: usize = 0;
		var tokens = std.mem.tokenizeAny(u8, codepoints_text, " \t");
		var skin = false;
		while (tokens.next()) |token| {
			const cp = std.fmt.parseInt(u21, token, 16) catch continue;
			if (cp >= 0x1F3FB and cp < 0x1F400) skin = true;
			if (count < codepoints.len) {
				codepoints[count] = cp;
				count += 1;
			}
		}
		if (skin or count == 0) continue;
		var key: std.ArrayList(u8) = .empty;
		var text: std.ArrayList(u8) = .empty;
		for (codepoints[0..count]) |cp| {
			var buffer: [4]u8 = undefined;
			const size = std.unicode.utf8Encode(cp, &buffer) catch continue;
			try text.appendSlice(allocator, buffer[0..size]);
			if (cp != 0xFE0F) try key.appendSlice(allocator, buffer[0..size]);
		}
		if ((try seen.getOrPut(allocator, key.items)).found_existing) continue;
		const annotation = english.get(key.items) orelse english.get(text.items) orelse continue;
		if (annotation.name.len == 0) continue;
		var keywords: std.StringHashMapUnmanaged(void) = .empty;
		for (langs) |language| {
			const map = annotations.get(language) orelse continue;
			const found = map.get(key.items) orelse map.get(text.items) orelse continue;
			for (found.keywords) |word| try keywords.put(allocator, word, {});
			if (found.name.len > 0) try keywords.put(allocator, found.name, {});
		}
		try entries.append(allocator, .{
			.kind = 0,
			.text = try text.toOwnedSlice(allocator),
			.name = uppercaseFirst(annotation.name),
			.keywords = keywords,
		});
	}
	const archive_path = try parser.fetch(kao_url, try std.fmt.allocPrint(allocator, "{s}/kaomoji-dataset-1.0.6.tgz", .{cache}));
	const jsonl_path = try std.fmt.allocPrint(allocator, "{s}/kaomoji-dataset-1.0.6.jsonl.gz", .{cache});
	if (!proc.exists(io, jsonl_path)) {
		const archive = try proc.readFileLimit(io, allocator, archive_path, 64 * 1024 * 1024);
		const tar_body = try gzipDecompress(allocator, archive);
		var reader = std.Io.Reader.fixed(tar_body);
		var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
		var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
		var iterator = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
		var found: ?[]u8 = null;
		while (try iterator.next()) |file| {
			if (file.kind == .file and std.mem.eql(u8, file.name, "package/data/kaomoji.jsonl.gz")) {
				var collecting: std.Io.Writer.Allocating = .init(allocator);
				try iterator.streamRemaining(file, &collecting.writer);
				found = try collecting.toOwnedSlice();
			}
		}
		const body = found orelse return error.MissingKaomoji;
		try proc.writeFileAtomic(io, allocator, jsonl_path, body);
	}
	const jsonl_gz = try proc.readFileLimit(io, allocator, jsonl_path, 64 * 1024 * 1024);
	const jsonl = try gzipDecompress(allocator, jsonl_gz);
	var kao_map: std.StringHashMapUnmanaged(usize) = .empty;
	var lines = std.mem.splitScalar(u8, jsonl, '\n');
	var entry_list: std.ArrayList(Entry) = .empty;
	while (lines.next()) |line| {
		if (line.len == 0) continue;
		const parsed = try json.parse(allocator, line);
		if (!std.mem.eql(u8, json.textAt(parsed.value, "tier"), "core")) continue;
		const raw_text = json.textAt(parsed.value, "text");
		var text: std.ArrayList(u8) = .empty;
		for (raw_text) |char| {
			try text.append(allocator, switch (char) {
				'\n', '\t' => ' ',
				else => char,
			});
		}
		if (text.items.len == 0) continue;
		var name: std.ArrayList(u8) = .empty;
		const names = json.field(parsed.value, "names") orelse continue;
		for (json.textAt(names, "en")) |char| {
			try name.append(allocator, switch (char) {
				'\n', '\t' => ' ',
				else => char,
			});
		}
		var keywords: std.StringHashMapUnmanaged(void) = .empty;
		for (kao_langs) |language| {
			if (json.field(parsed.value, "keywords")) |keyword_map| {
				if (json.field(keyword_map, language)) |items| {
					for (json.list(items)) |item| {
						const word = json.text(item);
						if (word.len > 0) try keywords.put(allocator, word, {});
					}
				}
			}
			const localized = json.textAt(names, language);
			if (localized.len > 0) try keywords.put(allocator, localized, {});
		}
		if (kao_map.get(text.items)) |index| {
			const old = &entry_list.items[index];
			var merged = old.keywords;
			var it = keywords.keyIterator();
			while (it.next()) |word| try merged.put(allocator, word.*, {});
			old.keywords = merged;
			if (old.name.len == 0) old.name = name.items;
		} else {
			kao_map.put(allocator, text.items, entry_list.items.len) catch continue;
			try entry_list.append(allocator, .{ .kind = 1, .text = text.items, .name = name.items, .keywords = keywords });
		}
	}
	try entries.appendSlice(allocator, entry_list.items);
	var keyword_set: std.StringHashMapUnmanaged(void) = .empty;
	for (entries.items) |entry| {
		var it = entry.keywords.keyIterator();
		while (it.next()) |word| {
			const trimmed = std.mem.trim(u8, word.*, " \t\r\n");
			if (trimmed.len == 0) continue;
			const lower = try std.ascii.allocLowerString(allocator, trimmed);
			try keyword_set.put(allocator, lower, {});
		}
	}
	var keyword_list: std.ArrayList([]const u8) = .empty;
	var keyword_it = keyword_set.keyIterator();
	while (keyword_it.next()) |word| try keyword_list.append(allocator, word.*);
	std.mem.sort([]const u8, keyword_list.items, {}, struct {
		fn lessThan(_: void, a: []const u8, b: []const u8) bool {
			return std.mem.order(u8, a, b) == .lt;
		}
	}.lessThan);
	var keyword_ids: std.StringHashMapUnmanaged(u32) = .empty;
	for (keyword_list.items, 0..) |word, index| try keyword_ids.put(allocator, word, @intCast(index));
	var pool: std.ArrayList(u8) = .empty;
	var offsets: std.StringHashMapUnmanaged(Ref) = .empty;
	var keyword_refs: std.ArrayList(Ref) = .empty;
	for (keyword_list.items) |word| try keyword_refs.append(allocator, try fileref(allocator, &pool, &offsets, word));
	var ids: std.ArrayList(u32) = .empty;
	var records: std.ArrayList(struct {
		kind: u8,
		text: Ref,
		name: Ref,
		lower: Ref,
		start: u32,
		count: u16,
	}) = .empty;
	for (entries.items) |entry| {
		const text_ref = try fileref(allocator, &pool, &offsets, entry.text);
		const name_ref = try fileref(allocator, &pool, &offsets, entry.name);
		const lower = try std.ascii.allocLowerString(allocator, entry.name);
		const lower_ref = try fileref(allocator, &pool, &offsets, lower);
		var entry_ids: std.ArrayList(u32) = .empty;
		var it = entry.keywords.keyIterator();
		while (it.next()) |word| {
			const trimmed = std.mem.trim(u8, word.*, " \t\r\n");
			if (trimmed.len == 0) continue;
			const lower_word = try std.ascii.allocLowerString(allocator, trimmed);
			const id = keyword_ids.get(lower_word) orelse continue;
			var duplicate = false;
			for (entry_ids.items) |known| {
				if (known == id) duplicate = true;
			}
			if (!duplicate) try entry_ids.append(allocator, id);
		}
		std.mem.sort(u32, entry_ids.items, {}, std.sort.asc(u32));
		const start: u32 = @intCast(ids.items.len);
		try ids.appendSlice(allocator, entry_ids.items);
		try records.append(allocator, .{
			.kind = entry.kind,
			.text = text_ref,
			.name = name_ref,
			.lower = lower_ref,
			.start = start,
			.count = @intCast(entry_ids.items.len),
		});
	}
	const id_size: u32 = if (keyword_list.items.len <= 65535) 2 else 4;
	var body: std.ArrayList(u8) = .empty;
	try body.appendSlice(allocator, "YIDX");
	var header: [24]u8 = undefined;
	std.mem.writeInt(u32, header[0..4], 1, .little);
	std.mem.writeInt(u32, header[4..8], @intCast(records.items.len), .little);
	std.mem.writeInt(u32, header[8..12], @intCast(keyword_list.items.len), .little);
	std.mem.writeInt(u32, header[12..16], @intCast(ids.items.len), .little);
	std.mem.writeInt(u32, header[16..20], id_size, .little);
	std.mem.writeInt(u32, header[20..24], @intCast(pool.items.len), .little);
	try body.appendSlice(allocator, &header);
	try body.appendSlice(allocator, pool.items);
	for (keyword_refs.items) |ref| {
		var raw: [8]u8 = undefined;
		std.mem.writeInt(u32, raw[0..4], ref.start, .little);
		std.mem.writeInt(u32, raw[4..8], ref.len, .little);
		try body.appendSlice(allocator, &raw);
	}
	for (ids.items) |id| {
		if (id_size == 2) {
			var raw: [2]u8 = undefined;
			std.mem.writeInt(u16, &raw, @intCast(id), .little);
			try body.appendSlice(allocator, &raw);
		} else {
			var raw: [4]u8 = undefined;
			std.mem.writeInt(u32, &raw, id, .little);
			try body.appendSlice(allocator, &raw);
		}
	}
	for (records.items) |record| {
		var raw: [33]u8 = undefined;
		raw[0] = record.kind;
		std.mem.writeInt(u32, raw[1..5], record.text.start, .little);
		std.mem.writeInt(u32, raw[5..9], record.text.len, .little);
		std.mem.writeInt(u32, raw[9..13], record.name.start, .little);
		std.mem.writeInt(u32, raw[13..17], record.name.len, .little);
		std.mem.writeInt(u32, raw[17..21], record.lower.start, .little);
		std.mem.writeInt(u32, raw[21..25], record.lower.len, .little);
		std.mem.writeInt(u32, raw[25..29], record.start, .little);
		std.mem.writeInt(u16, raw[29..31], record.count, .little);
		std.mem.writeInt(u16, raw[31..33], 0, .little);
		try body.appendSlice(allocator, &raw);
	}
	const gz = try gzipCompress(allocator, body.items);
	try proc.writeFileAtomic(io, allocator, out, gz);
	std.debug.print("launcher index: {d} entries, {d} keywords, {d} bytes\n", .{ records.items.len, keyword_list.items.len, gz.len });
}
