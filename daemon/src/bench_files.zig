const std = @import("std");
const json = @import("primitives/json.zig");
const proc = @import("primitives/proc.zig");
const fmt = @import("primitives/fmt.zig");
const index = @import("providers/files/index.zig");
const files = @import("providers/files/build.zig");
const find = @import("providers/files/find.zig");
const disk = @import("bench_disk.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Row = struct {
	cold: bool = false,
	at: i64,
	fixture: []const u8,
	entries: u64,
	directories: u64,
	bytes: u64,
	buildMs: f64,
	incrementalMs: f64,
	entriesPerSecond: f64,
	scanMs: f64,
	scanFolders: u64,
	loadMs: f64,
	queryP50Us: f64,
	queryP99Us: f64,
	accuracy: bool,
};

const Sink = struct {
	count: u64 = 0,

	pub fn found(self: *Sink, _: []const u8) !bool {
		self.count += 1;
		return true;
	}
};

pub fn run(io: Io, args: []const []const u8) !void {
	var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var as_json = false;
	var counts: usize = 20_000;
	var cold = false;
	var synthetic = true;
	var real = true;

	for (args) |arg| {
		if (std.mem.eql(u8, arg, "--live")) return live(io, allocator);
		if (std.mem.eql(u8, arg, "--json")) as_json = true;
		if (std.mem.eql(u8, arg, "--cold")) cold = true;
		if (std.mem.eql(u8, arg, "--synthetic")) {
			synthetic = true;
			real = false;
		}
		if (std.mem.eql(u8, arg, "--no-synthetic")) synthetic = false;
		if (std.mem.eql(u8, arg, "--no-real")) real = false;
		if (std.mem.startsWith(u8, arg, "--files=")) counts = std.fmt.parseInt(usize, arg["--files=".len..], 10) catch counts;
	}

	const cache_home = proc.env(io, allocator, "XDG_CACHE_HOME") orelse try std.fmt.allocPrint(allocator, "{s}/.cache", .{proc.home(io, allocator)});
	const scratch = try std.fmt.allocPrint(allocator, "{s}/yudae-files-bench-{d}", .{ cache_home, std.os.linux.getpid() });
	defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
	try std.Io.Dir.cwd().createDirPath(io, scratch);

	var baseline_row: ?Row = null;

	if (synthetic) {
		const fixture = try disk.makeFixture(io, allocator, scratch, counts);
		const home = try std.fmt.allocPrint(allocator, "{s}/deep", .{fixture});
		const out = try std.fmt.allocPrint(allocator, "{s}/synthetic.idx", .{scratch});
		const row = try measure(io, allocator, fixture, home, out, false, "synthetic");
		try append(io, allocator, row);
		try printRow(io, as_json, row);
		baseline_row = row;

		if (cold and disk.dropCaches(io, allocator, fixture)) {
			const cooled = try measure(io, allocator, fixture, home, out, true, "synthetic");
			try append(io, allocator, cooled);
			try printRow(io, as_json, cooled);
		}
	}

	if (real) {
		const home = proc.home(io, allocator);
		const out = try std.fmt.allocPrint(allocator, "{s}/home.idx", .{scratch});
		const row = try measure(io, allocator, "/", home, out, cold, "home");
		try append(io, allocator, row);
		try printRow(io, as_json, row);
	}

	if (baseline_row) |row| _ = try gate(io, allocator, row);
}

fn measure(io: Io, allocator: Allocator, root: []const u8, home: []const u8, out: []const u8, cold: bool, fixture: []const u8) !Row {
	var workspace = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
	defer workspace.deinit();
	const work = workspace.allocator();
	std.Io.Dir.cwd().deleteFile(io, out) catch {};
	if (cold and !disk.dropCaches(io, allocator, home)) std.debug.print("bench files: cold cache needs yudae-fsd and org.yudae.fs.bench\n", .{});

	const started = nowNs();
	try files.build(io, work, root, home, out, fmt.nowMs(io));
	const build_ns = nowNs() - started;

	const load_started = nowNs();
	var loaded = try index.load(io, out);
	defer loaded.deinit();
	const load_ns = nowNs() - load_started;

	const queries = try queryTimes(work, &loaded);
	const size: u64 = @intCast((std.Io.Dir.cwd().statFile(io, out, .{}) catch return error.StatFailed).size);

	const reuse_started = nowNs();
	try files.build(io, work, root, home, out, fmt.nowMs(io));
	const reuse_ns = nowNs() - reuse_started;

	var sink: Sink = .{};
	const scan_started = nowNs();
	_ = files.changes(work, &loaded, home, &sink) catch 0;
	const scan_ns = nowNs() - scan_started;

	return .{
		.cold = cold,
		.at = fmt.nowMs(io),
		.fixture = fixture,
		.entries = loaded.count,
		.directories = loaded.dirs.len,
		.bytes = size,
		.buildMs = @as(f64, @floatFromInt(build_ns)) / 1_000_000.0,
		.incrementalMs = @as(f64, @floatFromInt(reuse_ns)) / 1_000_000.0,
		.entriesPerSecond = if (build_ns > 0) @as(f64, @floatFromInt(loaded.count)) * 1_000_000_000.0 / @as(f64, @floatFromInt(build_ns)) else 0,
		.scanMs = @as(f64, @floatFromInt(scan_ns)) / 1_000_000.0,
		.scanFolders = loaded.dirs.len,
		.loadMs = @as(f64, @floatFromInt(load_ns)) / 1_000_000.0,
		.queryP50Us = queries.p50,
		.queryP99Us = queries.p99,
		.accuracy = queries.hit,
	};
}

fn queryTimes(allocator: Allocator, loaded: *const index.Index) !struct { p50: f64, p99: f64, hit: bool } {
	var samples: std.ArrayList(f64) = .empty;
	defer samples.deinit(allocator);

	var buf: [256]u8 = undefined;
	var hits: [64]u32 = undefined;
	const step = @max(@as(u32, 1), loaded.count / 500);
	var id: u32 = 0;
	var hit = false;
	while (id < loaded.count and samples.items.len < 500) : (id += step) {
		const item = loaded.item(id, &buf);
		if (item.name.len == 0) continue;
		const started = nowNs();
		const found = loaded.search(item.name, &hits);
		const ended = nowNs();
		hit = hit or found > 0;
		try samples.append(allocator, @as(f64, @floatFromInt(ended - started)) / 1000.0);
	}

	if (samples.items.len == 0) return .{ .p50 = 0, .p99 = 0, .hit = hit };
	std.mem.sort(f64, samples.items, {}, struct {
		fn less(_: void, a: f64, b: f64) bool {
			return a < b;
		}
	}.less);

	return .{
		.p50 = samples.items[samples.items.len / 2],
		.p99 = samples.items[@min(samples.items.len - 1, samples.items.len * 99 / 100)],
		.hit = hit,
	};
}

const live_queries = [_][]const u8{ "a", "c", "re", "png", "conf", "config", "main", "readme", "dotfiles", "zzzq" };
const live_runs = 20;

fn live(io: Io, allocator: Allocator) !void {
	const cache_home = proc.env(io, allocator, "XDG_CACHE_HOME") orelse try std.fmt.allocPrint(allocator, "{s}/.cache", .{proc.home(io, allocator)});
	const path = try std.fmt.allocPrint(allocator, "{s}/yudae/files.idx", .{cache_home});
	var loaded = try index.load(io, path);
	defer loaded.deinit();

	const dirs_started = nowNs();
	var dirs = try find.Dirs.init(allocator, &loaded, proc.home(io, allocator));
	defer dirs.deinit(allocator);
	const dirs_ns = nowNs() - dirs_started;
	const pool = try find.Pool.create(std.heap.smp_allocator, io);

	var buffer: [8192]u8 = undefined;
	var writer = std.Io.File.stdout().writer(io, &buffer);
	const w = &writer.interface;
	try w.print("live index {d} entries  {d} folders  folder table {d:.2}ms\n", .{ loaded.count, loaded.dirs.len, @as(f64, @floatFromInt(dirs_ns)) / 1e6 });

	for (live_queries) |query| {
		var samples: [live_runs]f64 = undefined;
		var matched: usize = 0;
		for (&samples) |*sample| {
			var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
			defer scratch.deinit();
			const started = nowNs();
			const result = try find.top(scratch.allocator(), pool, &loaded, &dirs, query, 24);
			sample.* = @as(f64, @floatFromInt(nowNs() - started)) / 1000.0;
			matched = result.matched;
		}
		std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
		try w.print("  {s:<10} {d:>8} matches  p50 {d:>8.0}us  max {d:>8.0}us\n", .{ query, matched, samples[live_runs / 2], samples[live_runs - 1] });
	}
	try w.flush();
}

fn nowNs() i128 {
	var ts: std.os.linux.timespec = undefined;
	if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
	return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn printRow(io: Io, as_json: bool, row: Row) !void {
	var buffer: [8192]u8 = undefined;
	var writer = std.Io.File.stdout().writer(io, &buffer);
	const w = &writer.interface;
	if (as_json) {
		try w.print("{f}\n", .{std.json.fmt(row, .{})});
	} else {
		try w.print("{s:<9} build {d:.1}ms  reuse {d:.1}ms  scan {d:.1}ms  load {d:.2}ms\n", .{ row.fixture, row.buildMs, row.incrementalMs, row.scanMs, row.loadMs });
		try w.print("          {d} entries  {d} folders  {d} bytes  {d:.0}/s\n", .{ row.entries, row.directories, row.bytes, row.entriesPerSecond });
		try w.print("          queries p50 {d:.2}us  p99 {d:.2}us  {s}\n", .{ row.queryP50Us, row.queryP99Us, if (row.accuracy) "hit" else "FAIL" });
	}
	try w.flush();
}

fn append(io: Io, allocator: Allocator, row: Row) !void {
	const dir = try std.fmt.allocPrint(allocator, "{s}/dotfiles/daemon/bench", .{proc.home(io, allocator)});
	try std.Io.Dir.cwd().createDirPath(io, dir);
	const path = try std.fmt.allocPrint(allocator, "{s}/files.jsonl", .{dir});
	const previous = proc.readFile(io, allocator, path) catch "";
	defer if (previous.len > 0) allocator.free(previous);

	var out: std.Io.Writer.Allocating = .init(allocator);
	try out.writer.writeAll(previous);
	try out.writer.print("{f}\n", .{std.json.fmt(row, .{})});
	try proc.writeFileAtomic(io, allocator, path, out.written());
}

fn gate(io: Io, allocator: Allocator, row: Row) !bool {
	const path = try std.fmt.allocPrint(allocator, "{s}/dotfiles/daemon/bench/baseline.json", .{proc.home(io, allocator)});
	const body = proc.readFile(io, allocator, path) catch return false;
	defer allocator.free(body);

	const parsed = json.parse(allocator, body) catch return false;
	const files_gate = json.field(parsed.value, "files") orelse {
		if (!row.accuracy) return false;

		var out: std.Io.Writer.Allocating = .init(allocator);
		const cut = std.mem.lastIndexOfScalar(u8, body, '}') orelse return false;
		try out.writer.writeAll(body[0..cut]);
		if (cut > 0 and body[cut - 1] != '{' and body[cut - 1] != ',') try out.writer.writeAll(",");
		try out.writer.writeAll("\"files\":");
		try out.writer.print("{f}", .{std.json.fmt(row, .{})});
		try out.writer.writeAll("}\n");
		try proc.writeFileAtomic(io, allocator, path, out.written());
		return true;
	};

	const baseline = json.number(json.field(files_gate, "entriesPerSecond"));
	if (baseline <= 0) return false;
	if (row.entriesPerSecond < baseline * 0.8) {
		std.debug.print("bench files: throughput {d:.0}/s below 80% of baseline {d:.0}/s\n", .{ row.entriesPerSecond, baseline });
		std.process.exit(1);
	}
	return false;
}

test "bench files code compiles" {
	try std.testing.expect(true);
}
