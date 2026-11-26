const std = @import("std");
const sock = @import("../../primitives/sock.zig");
const proc = @import("../../primitives/proc.zig");
const exec = @import("../../primitives/exec.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Paths = struct {
	qemu: []const u8,
	backend: []const u8,
	userspace: []const u8,
	share: []const u8,
};

pub fn paths(io: Io, allocator: Allocator) !Paths {
	const home = proc.home(io, allocator);
	const installed = "/opt/conduit/bin/qemu-system-x86_64";
	const local = try std.fmt.allocPrint(allocator, "{s}/qemu-linux/install/bin/qemu-system-x86_64", .{home});
	const qemu: []const u8 = if (std.c.getenv("YUDAE_NVIDIA_QEMU")) |value|
		std.mem.span(value)
	else if (proc.exists(io, local))
		local
	else
		installed;
	const backend: []const u8 = if (std.c.getenv("YUDAE_NVIDIA_BACKEND")) |value| std.mem.span(value) else "/opt/conduit/bin/conduit-backend";
	const userspace: []const u8 = if (std.c.getenv("YUDAE_NVIDIA_USERSPACE")) |value| std.mem.span(value) else "/opt/conduit/bin/conduit-userspace";
	const cache = proc.env(io, allocator, "XDG_CACHE_HOME") orelse try std.fmt.allocPrint(allocator, "{s}/.cache", .{home});
	const share = try std.fmt.allocPrint(allocator, "{s}/yudae/nvidia-share", .{cache});
	return .{
		.qemu = qemu,
		.backend = backend,
		.userspace = userspace,
		.share = share,
	};
}

pub fn available(io: Io, allocator: Allocator) bool {
	const p = paths(io, allocator) catch return false;
	if (!proc.exists(io, p.qemu) or !proc.exists(io, p.backend)) return false;
	if (!proc.exists(io, p.userspace)) return false;
	if (!proc.exists(io, "/dev/nvidia0") or !proc.exists(io, "/dev/nvidiactl")) return false;
	if (!driverSupported(io, allocator, p.backend)) return false;
	const cache = std.fs.path.dirname(std.fs.path.dirname(p.share) orelse return false) orelse return false;
	const manifest = std.fmt.allocPrint(allocator, "{s}/dotfiles/vm/images/current/manifest.json", .{cache}) catch return false;
	const body = proc.readFile(io, allocator, manifest) catch return false;
	return std.mem.indexOf(u8, body, "\"conduit-guest\"") != null;
}

/// The backend boots a guest without a GPU when its ABI tables miss the host
/// driver, so a driver missing from its supported list means the GL backend.
fn driverSupported(io: Io, allocator: Allocator, backend: []const u8) bool {
	const prefix = std.fs.path.dirname(std.fs.path.dirname(backend) orelse return false) orelse return false;
	const list_path = std.fmt.allocPrint(allocator, "{s}/share/conduit/supported-drivers.txt", .{prefix}) catch return false;
	const list = proc.readFile(io, allocator, list_path) catch return false;
	const version = proc.readFile(io, allocator, "/sys/module/nvidia/version") catch return false;
	return listed(list, std.mem.trim(u8, version, " \t\r\n"));
}

fn listed(list: []const u8, version: []const u8) bool {
	var lines = std.mem.tokenizeAny(u8, list, "\r\n");
	while (lines.next()) |line| {
		if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), version)) return true;
	}
	return false;
}

test "a driver counts only when its own release is listed" {
	try std.testing.expect(listed("615.71.09\n620.73.04\n", "620.73.04"));
	try std.testing.expect(!listed("620.70.06\n620.73.040\n", "620.73.04"));
	try std.testing.expect(!listed("", "620.73.04"));
}

pub fn ensureShare(io: Io, allocator: Allocator) ![]const u8 {
	const p = try paths(io, allocator);
	const marker = try std.fmt.allocPrint(allocator, "{s}/lib/libEGL_nvidia.so.0", .{p.share});
	if (proc.exists(io, marker)) return p.share;

	try std.Io.Dir.cwd().createDirPath(io, p.share);
	const result = exec.run(io, allocator, &.{ p.userspace, "--stage", p.share, "--caps", "graphics,video,utility,compute" }) catch return error.ShareFailed;
	defer result.deinit(allocator);
	if (result.code != 0) return error.ShareFailed;
	return p.share;
}

pub fn backendArgs(allocator: Allocator, dir: []const u8, backend: []const u8) ![]const []const u8 {
	var list: std.ArrayList([]const u8) = .empty;
	try list.append(allocator, backend);
	const socket = try std.fmt.allocPrint(allocator, "{s}/nvgpu.sock", .{dir});
	const display = try std.fmt.allocPrint(allocator, "{s}/display-nvidia.sock", .{dir});
	const console = try std.fmt.allocPrint(allocator, "{s}/console-nvidia.sock", .{dir});
	try addPair(allocator, &list, "--socket", socket);
	try addPair(allocator, &list, "--caps", "graphics,video,utility,compute");
	try addPair(allocator, &list, "--display", "2560x1440@240");
	try addPair(allocator, &list, "--display-socket", display);
	try addPair(allocator, &list, "--console-vnc", console);
	try addPair(allocator, &list, "--window-mib", "auto");
	try addPair(allocator, &list, "--power-socket", try std.fmt.allocPrint(allocator, "{s}/power.sock", .{dir}));
	try list.append(allocator, "--allow-nearest-abi");
	return list.toOwnedSlice(allocator);
}

/// One line to the backend's power socket (keep, hold MS, release), one line back.
pub fn power(dir: []const u8, command: []const u8) bool {
	var path_buffer: [256]u8 = undefined;
	const path = std.fmt.bufPrint(&path_buffer, "{s}/power.sock", .{dir}) catch return false;
	var buffer: [512]u8 = undefined;
	var connection = sock.Connection.connect(path, &buffer) catch return false;
	defer connection.close();
	connection.writeLine(command) catch return false;
	const line = (connection.readLine() catch return false) orelse return false;
	return line.len > 0;
}

pub const Audio = enum { none, pa, alsa };

pub const Config = struct {
	name: []const u8,
	dir: []const u8,
	disk: []const u8,
	dotfiles: []const u8,
	share: []const u8,
	cid: u32,
	cores: u32,
	mem_mb: u32,
	qemu: []const u8,
	wallpaper: bool = false,
	state: bool = false,
	audio: Audio = .none,
	audio_index: u8 = 0,
	pkg: bool = false,
	kernel: []const u8 = "",
	cmdline: []const u8 = "",
};

pub fn args(allocator: Allocator, config: Config) ![]const []const u8 {
	var list: std.ArrayList([]const u8) = .empty;

	const qmp = try std.fmt.allocPrint(allocator, "{s}/qmp.sock", .{config.dir});
	const serial = try std.fmt.allocPrint(allocator, "{s}/serial.log", .{config.dir});
	const vfs = try std.fmt.allocPrint(allocator, "{s}/virtiofsd.sock", .{config.dir});
	const nvfs = try std.fmt.allocPrint(allocator, "{s}/nvidiafsd.sock", .{config.dir});
	const nvgpu = try std.fmt.allocPrint(allocator, "{s}/nvgpu.sock", .{config.dir});
	const mem = try std.fmt.allocPrint(allocator, "memory-backend-memfd,id=mem,size={d}M,share=on", .{config.mem_mb});

	try list.append(allocator, config.qemu);
	try addPair(allocator, &list, "-name", try std.fmt.allocPrint(allocator, "yudae-{s}", .{config.name}));
	try addPair(allocator, &list, "-machine", "q35,accel=kvm,memory-backend=mem");
	try addPair(allocator, &list, "-cpu", "host,host-phys-bits=on");
	try addPair(allocator, &list, "-rtc", "base=utc,clock=host");
	try list.append(allocator, "-nodefaults");
	try addPair(allocator, &list, "-smp", try std.fmt.allocPrint(allocator, "{d}", .{config.cores}));
	try addPair(allocator, &list, "-m", try std.fmt.allocPrint(allocator, "{d}M", .{config.mem_mb}));
	try addPair(allocator, &list, "-object", mem);
	try addPair(allocator, &list, "-drive", try std.fmt.allocPrint(allocator, "file={s},if=virtio,format=qcow2,cache=none,id=disk0", .{config.disk}));
	switch (config.audio) {
		.alsa => try addPair(allocator, &list, "-audiodev", try std.fmt.allocPrint(allocator, "alsa,id=snd0,out.dev=yudae{d},out.frequency=48000,out.channels=2,out.format=s16", .{config.audio_index})),
		.pa => try addPair(allocator, &list, "-audiodev", "pa,id=snd0"),
		.none => try addPair(allocator, &list, "-audiodev", "none,id=snd0"),
	}
	try addPair(allocator, &list, "-device", "ich9-intel-hda");
	try addPair(allocator, &list, "-device", "hda-output,audiodev=snd0");
	try addPair(allocator, &list, "-device", try std.fmt.allocPrint(allocator, "vhost-vsock-pci,guest-cid={d}", .{config.cid}));
	try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=vfs0,path={s}", .{vfs}));
	try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=vfs0,tag=dotfiles");
	try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=nvfs0,path={s}", .{nvfs}));
	try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=nvfs0,tag=nvidia");
	if (config.wallpaper) {
		try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=wall0,path={s}/wallpaper.sock", .{config.dir}));
		try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=wall0,tag=wallpaper");
	}
	if (config.state) {
		try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=state0,path={s}/state.sock", .{config.dir}));
		try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=state0,tag=yudae-state");
	}
	if (config.pkg) {
		try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=pkg0,path={s}/hostpkg.sock", .{config.dir}));
		try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=pkg0,tag=hostpkg");
	}
	try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=nvgpu,path={s}", .{nvgpu}));
	try addPair(allocator, &list, "-device", "vhost-user-test-device-pci,chardev=nvgpu,virtio-id=45,num_vqs=3,vq_size=256,config_size=4036,class=0x380");
	try addPair(allocator, &list, "-vga", "std");
	try addPair(allocator, &list, "-device", "virtio-rng-pci");
	try addPair(allocator, &list, "-device", "virtio-tablet-pci");
	try addPair(allocator, &list, "-device", "virtio-keyboard-pci");
	try addPair(allocator, &list, "-netdev", try std.fmt.allocPrint(allocator, "stream,id=net0,server=off,addr.type=unix,addr.path={s}/passt.sock", .{config.dir}));
	try addPair(allocator, &list, "-device", "virtio-net-pci,netdev=net0");
	try addPair(allocator, &list, "-qmp", try std.fmt.allocPrint(allocator, "unix:{s},server=on,wait=off", .{qmp}));
	try addPair(allocator, &list, "-serial", try std.fmt.allocPrint(allocator, "file:{s}", .{serial}));
	try addPair(allocator, &list, "-monitor", "none");
	try addPair(allocator, &list, "-display", "none");
	if (config.kernel.len > 0) {
		try addPair(allocator, &list, "-kernel", config.kernel);
		try addPair(allocator, &list, "-append", config.cmdline);
	}
	try list.append(allocator, "-no-reboot");

	return list.toOwnedSlice(allocator);
}

fn addPair(allocator: Allocator, list: *std.ArrayList([]const u8), flag: []const u8, value: []const u8) !void {
	try list.append(allocator, flag);
	try list.append(allocator, value);
}
