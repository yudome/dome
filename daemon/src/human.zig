const std = @import("std");
const json = @import("primitives/json.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const Writer = std.Io.Writer;
const Error = Writer.Error || Allocator.Error || error{InvalidUtf8};

pub fn write(allocator: Allocator, w: *Writer, value: Value, depth: usize) !void {
	switch (value) {
		.object => |object| {
			if (object.count() == 0) return;
			if (object.count() == 1) if (object.get("ok")) |ok| if (ok == .bool and ok.bool) return w.writeAll("done\n");
			try objectLines(allocator, w, object, 0, depth);
		},
		.array => |array| try arrayLines(allocator, w, array.items, 0, depth),
		.string => |text| try textBlock(w, text, 0),
		else => {
			try w.writeAll(try scalarText(allocator, value));
			try w.writeAll("\n");
		},
	}
}

fn objectLines(allocator: Allocator, w: *Writer, object: std.json.ObjectMap, indent: usize, depth: usize) Error!void {
	var width: usize = 0;
	for (object.keys(), object.values()) |key, item| {
		if (oneLine(item) or depth == 0) width = @max(width, try columns(try label(allocator, key)));
	}

	for (object.keys(), object.values()) |key, item| {
		const name = try label(allocator, key);
		try w.splatByteAll(' ', indent);
		try w.writeAll(name);

		if (oneLine(item)) {
			try w.splatByteAll(' ', width - try columns(name) + 2);
			try w.writeAll(try lineText(allocator, item));
			try w.writeAll("\n");
			continue;
		}

		if (depth == 0) {
			try w.splatByteAll(' ', width - try columns(name) + 2);
			try w.print("{d} {s}\n", .{ size(item), if (item == .array) "items" else "fields" });
			continue;
		}

		try w.writeAll("\n");
		switch (item) {
			.object => |child| try objectLines(allocator, w, child, indent + 2, depth - 1),
			.array => |child| try arrayLines(allocator, w, child.items, indent + 2, depth - 1),
			.string => |text| try textBlock(w, text, indent + 2),
			else => {},
		}
	}
}

fn arrayLines(allocator: Allocator, w: *Writer, items: []const Value, indent: usize, depth: usize) Error!void {
	if (items.len == 0) {
		try w.splatByteAll(' ', indent);
		return w.writeAll("none\n");
	}

	if (allObjects(items) and try table(allocator, w, items, indent)) return;

	for (items, 0..) |item, index| {
		switch (item) {
			.object => |object| {
				if (index > 0) try w.writeAll("\n");
				try objectLines(allocator, w, object, indent, depth);
			},
			.array => |array| try arrayLines(allocator, w, array.items, indent + 2, depth),
			.string => |text| try textBlock(w, text, indent),
			else => {
				try w.splatByteAll(' ', indent);
				try w.writeAll(try scalarText(allocator, item));
				try w.writeAll("\n");
			},
		}
	}
}

fn table(allocator: Allocator, w: *Writer, items: []const Value, indent: usize) !bool {
	var keys: std.ArrayList([]const u8) = .empty;
	for (items) |item| {
		for (item.object.keys()) |key| {
			if (contains(keys.items, key)) continue;
			if (!scalarEverywhere(items, key)) continue;
			if (emptyEverywhere(items, key)) continue;
			try keys.append(allocator, key);
		}
	}
	if (keys.items.len == 0) return false;

	const widths = try allocator.alloc(usize, keys.items.len);
	for (keys.items, 0..) |key, column| widths[column] = try columns(try label(allocator, key));
	for (items) |item| {
		for (keys.items, 0..) |key, column| widths[column] = @max(widths[column], try columns(try cell(allocator, item, key)));
	}

	try w.splatByteAll(' ', indent);
	for (keys.items, 0..) |key, column| try cellOut(w, try label(allocator, key), widths, column);
	try w.writeAll("\n");

	for (items) |item| {
		try w.splatByteAll(' ', indent);
		for (keys.items, 0..) |key, column| try cellOut(w, try cell(allocator, item, key), widths, column);
		try w.writeAll("\n");
	}
	return true;
}

fn cellOut(w: *Writer, text: []const u8, widths: []const usize, column: usize) !void {
	try w.writeAll(text);
	if (column + 1 < widths.len) try w.splatByteAll(' ', widths[column] - (columns(text) catch text.len) + 2);
}

fn cell(allocator: Allocator, item: Value, key: []const u8) ![]const u8 {
	const value = item.object.get(key) orelse return "-";
	return scalarText(allocator, value);
}

fn textBlock(w: *Writer, text: []const u8, indent: usize) !void {
	var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
	while (lines.next()) |line| {
		try w.splatByteAll(' ', indent);
		try w.writeAll(line);
		try w.writeAll("\n");
	}
}

fn lineText(allocator: Allocator, value: Value) ![]const u8 {
	switch (value) {
		.array => |array| {
			if (array.items.len == 0) return "none";
			var out: std.Io.Writer.Allocating = .init(allocator);
			for (array.items, 0..) |item, index| {
				if (index > 0) try out.writer.writeAll(", ");
				try out.writer.writeAll(try scalarText(allocator, item));
			}
			return out.written();
		},
		.object => return "none",
		else => return scalarText(allocator, value),
	}
}

fn scalarText(allocator: Allocator, value: Value) ![]const u8 {
	return switch (value) {
		.null => "-",
		.bool => |on| if (on) "yes" else "no",
		.integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
		.float => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
		.number_string => |text| text,
		.string => |text| if (text.len == 0) "-" else text,
		.array, .object => try std.fmt.allocPrint(allocator, "{d} {s}", .{ size(value), if (value == .array) "items" else "fields" }),
	};
}

fn label(allocator: Allocator, key: []const u8) ![]const u8 {
	var out: std.ArrayList(u8) = .empty;
	for (key, 0..) |char, index| {
		if (std.ascii.isUpper(char)) {
			if (index > 0 and !std.ascii.isUpper(key[index - 1])) try out.append(allocator, ' ');
			try out.append(allocator, std.ascii.toLower(char));
		} else if (char == '_' or char == '-') {
			try out.append(allocator, ' ');
		} else {
			try out.append(allocator, char);
		}
	}
	return out.items;
}

fn oneLine(value: Value) bool {
	return switch (value) {
		.string => |text| std.mem.indexOfScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n') == null,
		.array => |array| for (array.items) |item| {
			if (!scalar(item)) break false;
		} else true,
		.object => |object| object.count() == 0,
		else => true,
	};
}

fn scalar(value: Value) bool {
	return switch (value) {
		.array, .object => false,
		.string => |text| std.mem.indexOfScalar(u8, text, '\n') == null,
		else => true,
	};
}

fn scalarEverywhere(items: []const Value, key: []const u8) bool {
	for (items) |item| {
		if (item.object.get(key)) |value| if (!scalar(value)) return false;
	}
	return true;
}

fn emptyEverywhere(items: []const Value, key: []const u8) bool {
	for (items) |item| {
		const value = item.object.get(key) orelse continue;
		switch (value) {
			.null => {},
			.string => |text| if (text.len > 0) return false,
			else => return false,
		}
	}
	return true;
}

fn allObjects(items: []const Value) bool {
	for (items) |item| if (item != .object) return false;
	return true;
}

fn contains(list: []const []const u8, key: []const u8) bool {
	for (list) |item| if (std.mem.eql(u8, item, key)) return true;
	return false;
}

fn size(value: Value) usize {
	return switch (value) {
		.array => |array| array.items.len,
		.object => |object| object.count(),
		else => 1,
	};
}

fn columns(text: []const u8) !usize {
	return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn render(allocator: Allocator, body: []const u8, depth: usize) ![]const u8 {
	const parsed = try json.parse(allocator, body);
	var out: std.Io.Writer.Allocating = .init(allocator);
	try write(allocator, &out.writer, parsed.value, depth);
	return out.written();
}

test "a list of records is a table with word headers" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try render(arena.allocator(),
		\\[{"name":"a","tier":"off","memMb":4096,"gl":true},{"name":"longer","tier":"hot","memMb":512,"gl":false}]
	, 4);
	try std.testing.expectEqualStrings(
		"name    tier  mem mb  gl\n" ++
			"a       off   4096    yes\n" ++
			"longer  hot   512     no\n",
		out,
	);
}

test "objects align their keys and nest the rest" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const out = try render(arena.allocator(),
		\\{"load":["foot"],"failure":"","plugin":{"id":"foot","sessionTitle":"x"},"log":"one\ntwo"}
	, 4);
	try std.testing.expectEqualStrings(
		"load     foot\n" ++
			"failure  -\n" ++
			"plugin\n" ++
			"  id             foot\n" ++
			"  session title  x\n" ++
			"log\n" ++
			"  one\n" ++
			"  two\n",
		out,
	);
}

test "ok alone is done, empty is silent, depth summarizes" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const a = arena.allocator();
	try std.testing.expectEqualStrings("done\n", try render(a, "{\"ok\":true}", 4));
	try std.testing.expectEqualStrings("", try render(a, "{}", 4));
	try std.testing.expectEqualStrings("cpu  2 fields\n", try render(a, "{\"cpu\":{\"pct\":3,\"cores\":[1,2]}}", 0));
}
