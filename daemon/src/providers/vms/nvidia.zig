const std = @import("std");
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
	const qemu: []const u8 = if (std.c.getenv("YUDAE_NVIDIA_QEMU")) |value| std.mem.span(value) else "/home/gabriel/qemu-linux/install/bin/qemu-system-x86_64";
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
	const repo = proc.repo(io, allocator);
	const manifest = std.fmt.allocPrint(allocator, "{s}/vm/packages.txt", .{repo}) catch return false;
	if (!proc.exists(io, manifest)) return false;
	const body = proc.readFile(io, allocator, manifest) catch return false;
	return std.mem.indexOf(u8, body, "conduit-guest") != null;
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
	try addPair(allocator, &list, "--window-mib", "256");
	try list.append(allocator, "--allow-nearest-abi");
	return list.toOwnedSlice(allocator);
}

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
	host_audio: bool = false,
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
	try addPair(allocator, &list, "-audiodev", if (config.host_audio) "pa,id=snd0" else "none,id=snd0");
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
	try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=nvgpu,path={s}", .{nvgpu}));
	try addPair(allocator, &list, "-device", "vhost-user-test-device-pci,chardev=nvgpu,virtio-id=45,num_vqs=3,vq_size=256,config_size=4036,class=0x380");
	try addPair(allocator, &list, "-vga", "std");
	try addPair(allocator, &list, "-device", "virtio-rng-pci");
	try addPair(allocator, &list, "-device", "virtio-tablet-pci");
	try addPair(allocator, &list, "-device", "virtio-keyboard-pci");
	try addPair(allocator, &list, "-netdev", "user,id=net0");
	try addPair(allocator, &list, "-device", "virtio-net-pci,netdev=net0");
	try addPair(allocator, &list, "-qmp", try std.fmt.allocPrint(allocator, "unix:{s},server=on,wait=off", .{qmp}));
	try addPair(allocator, &list, "-serial", try std.fmt.allocPrint(allocator, "file:{s}", .{serial}));
	try addPair(allocator, &list, "-monitor", "none");
	try addPair(allocator, &list, "-display", "none");
	try list.append(allocator, "-no-reboot");

	return list.toOwnedSlice(allocator);
}

fn addPair(allocator: Allocator, list: *std.ArrayList([]const u8), flag: []const u8, value: []const u8) !void {
	try list.append(allocator, flag);
	try list.append(allocator, value);
}
