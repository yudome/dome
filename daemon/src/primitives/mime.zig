const std = @import("std");
const proc = @import("proc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Map = std.StringHashMapUnmanaged([]const u8);

const Glob = struct { mime: []const u8, weight: u32, pattern: [:0]const u8 };

extern "c" fn fnmatch(pattern: [*:0]const u8, string: [*:0]const u8, flags: c_int) c_int;

const sniff_bytes = 512;

const user_dirs = [_]struct { key: []const u8, icon: []const u8 }{
	.{ .key = "XDG_DESKTOP_DIR", .icon = "user-desktop" },
	.{ .key = "XDG_DOCUMENTS_DIR", .icon = "folder-documents" },
	.{ .key = "XDG_DOWNLOAD_DIR", .icon = "folder-download" },
	.{ .key = "XDG_MUSIC_DIR", .icon = "folder-music" },
	.{ .key = "XDG_PICTURES_DIR", .icon = "folder-pictures" },
	.{ .key = "XDG_PUBLICSHARE_DIR", .icon = "folder-publicshare" },
	.{ .key = "XDG_TEMPLATES_DIR", .icon = "folder-templates" },
	.{ .key = "XDG_VIDEOS_DIR", .icon = "folder-videos" },
};

pub const Mime = struct {
	arena: std.heap.ArenaAllocator,
	io: Io,
	mutex: std.Io.Mutex = .init,
	loaded: bool = false,
	suffixes: std.StringHashMapUnmanaged(Glob) = .empty,
	literals: Map = .empty,
	patterns: std.ArrayList(Glob) = .empty,
	generic: Map = .empty,
	places: Map = .empty,

	pub fn init(allocator: Allocator, io: Io) Mime {
		return .{ .arena = std.heap.ArenaAllocator.init(allocator), .io = io };
	}

	pub fn warm(self: *Mime) void {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		self.load();
	}

	fn load(self: *Mime) void {
		if (self.loaded) return;
		self.loaded = true;
		const a = self.arena.allocator();

		self.parseGlobs(a, proc.readFileOr(self.io, a, "/usr/share/mime/globs2")) catch {};
		parsePairs(a, proc.readFileOr(self.io, a, "/usr/share/mime/generic-icons"), &self.generic) catch {};

		const home = proc.home(self.io, a);
		self.places.put(a, home, "user-home") catch {};
		const dirs_path = std.fmt.allocPrint(a, "{s}/.config/user-dirs.dirs", .{home}) catch return;
		parseUserDirs(a, proc.readFileOr(self.io, a, dirs_path), home, &self.places) catch {};
	}

	pub fn icons(self: *Mime, arena: Allocator, path: []const u8, dir: bool) []const []const u8 {
		self.mutex.lockUncancelable(self.io);
		defer self.mutex.unlock(self.io);
		self.load();

		var out: std.ArrayList([]const u8) = .empty;

		if (dir) {
			if (self.places.get(path)) |name| out.append(arena, name) catch {};
			out.append(arena, "folder") catch {};
			return out.items;
		}

		const mime = self.typeOf(arena, std.fs.path.basename(path)) orelse self.sniff(path);
		self.chain(arena, mime, &out) catch {};
		return out.items;
	}

	fn chain(self: *Mime, arena: Allocator, mime: []const u8, out: *std.ArrayList([]const u8)) !void {
		const exact = try arena.dupe(u8, mime);
		std.mem.replaceScalar(u8, exact, '/', '-');
		try out.append(arena, exact);
		if (self.generic.get(mime)) |name| try out.append(arena, name);
		const slash = std.mem.indexOfScalar(u8, mime, '/') orelse mime.len;
		try out.append(arena, try std.fmt.allocPrint(arena, "{s}-x-generic", .{mime[0..slash]}));
		try out.append(arena, "unknown");
	}

	fn sniff(self: *Mime, path: []const u8) []const u8 {
		var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return "application/octet-stream";
		defer file.close(self.io);
		var buffer: [sniff_bytes]u8 = undefined;
		var staging: [sniff_bytes]u8 = undefined;
		var reader = file.reader(self.io, &staging);
		const count = reader.interface.readSliceShort(&buffer) catch return "application/octet-stream";
		return textOrBinary(buffer[0..count]);
	}

	pub fn typeOf(self: *Mime, arena: Allocator, name: []const u8) ?[]const u8 {
		const lower = std.ascii.allocLowerString(arena, name) catch return null;
		if (self.literals.get(lower)) |mime| return mime;

		var best: ?Glob = null;

		for (lower, 0..) |byte, index| {
			if (byte != '.') continue;
			if (self.suffixes.get(lower[index..])) |hit| {
				best = hit;
				break;
			}
		}

		const z = arena.dupeSentinel(u8, lower, 0) catch return if (best) |hit| hit.mime else null;
		for (self.patterns.items) |glob| {
			if (fnmatch(glob.pattern.ptr, z.ptr, 0) != 0) continue;
			if (best) |hit| {
				if (glob.weight < hit.weight or (glob.weight == hit.weight and glob.pattern.len <= hit.pattern.len)) continue;
			}
			best = glob;
		}

		return if (best) |hit| hit.mime else null;
	}

	fn parseGlobs(self: *Mime, a: Allocator, body: []const u8) !void {
		var lines = std.mem.splitScalar(u8, body, '\n');

		while (lines.next()) |line| {
			if (line.len == 0 or line[0] == '#') continue;
			var fields = std.mem.splitScalar(u8, line, ':');
			const weight = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
			const mime = fields.next() orelse continue;
			const pattern = try std.ascii.allocLowerString(a, fields.next() orelse continue);

			if (std.mem.indexOfAny(u8, pattern, "*?[") == null) {
				const entry = try self.literals.getOrPut(a, pattern);
				if (!entry.found_existing) entry.value_ptr.* = mime;
				continue;
			}

			const glob: Glob = .{ .mime = mime, .weight = weight, .pattern = try a.dupeSentinel(u8, pattern, 0) };

			if (std.mem.startsWith(u8, pattern, "*.") and std.mem.indexOfAny(u8, pattern[1..], "*?[") == null) {
				const entry = try self.suffixes.getOrPut(a, pattern[1..]);
				if (!entry.found_existing) entry.value_ptr.* = glob;
				continue;
			}

			try self.patterns.append(a, glob);
		}
	}
};

fn textOrBinary(head: []const u8) []const u8 {
	if (head.len == 0) return "application/x-zerosize";
	return if (std.mem.indexOfScalar(u8, head, 0) == null) "text/plain" else "application/octet-stream";
}

fn parsePairs(a: Allocator, body: []const u8, map: *Map) !void {
	var lines = std.mem.splitScalar(u8, body, '\n');

	while (lines.next()) |line| {
		const split = std.mem.indexOfScalar(u8, line, ':') orelse continue;
		try map.put(a, line[0..split], line[split + 1 ..]);
	}
}

fn parseUserDirs(a: Allocator, body: []const u8, home: []const u8, map: *Map) !void {
	var lines = std.mem.splitScalar(u8, body, '\n');

	while (lines.next()) |line| {
		const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..split], " \t");
		const value = std.mem.trim(u8, line[split + 1 ..], " \t\"");

		for (user_dirs) |dir| {
			if (!std.mem.eql(u8, dir.key, key)) continue;
			const full = if (std.mem.startsWith(u8, value, "$HOME")) try std.fmt.allocPrint(a, "{s}{s}", .{ home, value["$HOME".len..] }) else value;
			const path = std.mem.trimEnd(u8, full, "/");
			if (!std.mem.eql(u8, path, home)) try map.put(a, path, dir.icon);
		}
	}
}

test "a file name finds its mime type and the icon names to try" {
	var mime = Mime.init(std.testing.allocator, std.testing.io);
	defer mime.arena.deinit();
	mime.loaded = true;
	const a = mime.arena.allocator();

	try mime.parseGlobs(a, "# x\n60:application/x-sharedlib:*.so.[0-9]*\n50:application/x-compressed-tar:*.tar.gz\n50:application/gzip:*.gz\n50:text/rust:*.rs\n50:text/x-makefile:makefile\n50:application/x-troff-man:*.[1-9]\n10:text/x-makefile:makefile.*\n10:text/x-readme:README*\n10:text/plain:*.rs\n50:text/markdown:*.md\n");
	try parsePairs(a, "application/x-compressed-tar:package-x-generic\n", &mime.generic);

	try std.testing.expectEqualStrings("text/rust", mime.typeOf(a, "Main.RS").?);
	try std.testing.expectEqualStrings("application/x-compressed-tar", mime.typeOf(a, "a.tar.gz").?);
	try std.testing.expectEqualStrings("application/gzip", mime.typeOf(a, "a.gz").?);
	try std.testing.expectEqualStrings("text/x-makefile", mime.typeOf(a, "Makefile").?);
	try std.testing.expectEqualStrings("text/x-readme", mime.typeOf(a, "README").?);
	try std.testing.expectEqualStrings("text/x-readme", mime.typeOf(a, "Readme.txt").?);
	try std.testing.expectEqualStrings("text/markdown", mime.typeOf(a, "README.md").?);
	try std.testing.expectEqualStrings("text/x-makefile", mime.typeOf(a, "Makefile.am").?);
	try std.testing.expectEqualStrings("application/x-sharedlib", mime.typeOf(a, "libc.so.6").?);
	try std.testing.expectEqualStrings("application/x-troff-man", mime.typeOf(a, "ls.1").?);
	try std.testing.expect(mime.typeOf(a, ".zshrc") == null);

	var out: std.ArrayList([]const u8) = .empty;
	try mime.chain(a, "application/x-compressed-tar", &out);
	const want = [_][]const u8{ "application-x-compressed-tar", "package-x-generic", "application-x-generic", "unknown" };
	for (want, out.items) |expected, got| try std.testing.expectEqualStrings(expected, got);

	try std.testing.expectEqualStrings("text/plain", textOrBinary("fn main() {}\n"));
	try std.testing.expectEqualStrings("application/octet-stream", textOrBinary("\x7fELF\x00\x01"));
	try std.testing.expectEqualStrings("application/x-zerosize", textOrBinary(""));

	try parseUserDirs(a, "XDG_DOWNLOAD_DIR=\"$HOME/Downloads\"\nXDG_DESKTOP_DIR=\"$HOME/\"\n", "/home/u", &mime.places);
	try std.testing.expectEqualStrings("folder-download", mime.places.get("/home/u/Downloads").?);
	try std.testing.expect(mime.places.get("/home/u") == null);
}
