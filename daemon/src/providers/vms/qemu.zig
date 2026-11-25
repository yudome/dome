const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Audio = enum { none, pa, alsa };

pub const Config = struct {
	name: []const u8,
	dir: []const u8,
	disk: []const u8,
	dotfiles: []const u8,
	wallpaper_dir: []const u8 = "",
	state: bool = false,
	cores: u32,
	mem_mb: u32,
	cid: u32,
	gl: bool,
	audio: Audio = .none,
	audio_index: u8 = 0,
};

pub fn binary() []const u8 {
	return if (std.c.getenv("YUDAE_QEMU")) |value| std.mem.span(value) else "qemu-system-x86_64";
}

pub fn args(allocator: Allocator, config: Config) ![]const []const u8 {
	var list: std.ArrayList([]const u8) = .empty;

	const qmp = try std.fs.path.join(allocator, &.{ config.dir, "qmp.sock" });
	const display_qmp = try std.fs.path.join(allocator, &.{ config.dir, "display.qmp" });
	const serial = try std.fs.path.join(allocator, &.{ config.dir, "serial.log" });
	const vfs = try std.fs.path.join(allocator, &.{ config.dir, "virtiofsd.sock" });
	const wall = try std.fs.path.join(allocator, &.{ config.dir, "wallpaper.sock" });

	try list.append(allocator, binary());
	try addPair(allocator, &list, "-name", try std.fmt.allocPrint(allocator, "yudae-{s}", .{config.name}));
	try addPair(allocator, &list, "-machine", "q35,accel=kvm");
	try addPair(allocator, &list, "-rtc", "base=utc,clock=host");
	try list.append(allocator, "-nodefaults");
	try addPair(allocator, &list, "-cpu", "host");
	try addPair(allocator, &list, "-smp", try std.fmt.allocPrint(allocator, "{d}", .{config.cores}));
	try addPair(allocator, &list, "-m", try std.fmt.allocPrint(allocator, "{d}M", .{config.mem_mb}));
	try addPair(allocator, &list, "-object", try std.fmt.allocPrint(allocator, "memory-backend-memfd,id=mem,size={d}M,share=on", .{config.mem_mb}));
	try addPair(allocator, &list, "-numa", "node,memdev=mem");
	try addPair(allocator, &list, "-drive", try std.fmt.allocPrint(allocator, "file={s},if=virtio,format=qcow2,cache=none,aio=io_uring,id=disk0", .{config.disk}));
	switch (config.audio) {
		.alsa => try addPair(allocator, &list, "-audiodev", try std.fmt.allocPrint(allocator, "alsa,id=snd0,out.dev=yudae{d},out.frequency=48000,out.channels=2,out.format=s16", .{config.audio_index})),
		.pa => try addPair(allocator, &list, "-audiodev", "pa,id=snd0"),
		.none => try addPair(allocator, &list, "-audiodev", "none,id=snd0"),
	}
	try addPair(allocator, &list, "-device", "ich9-intel-hda");
	try addPair(allocator, &list, "-device", "hda-output,audiodev=snd0");

	if (config.gl) {
		try addPair(allocator, &list, "-device", "virtio-gpu-gl-pci,xres=2560,yres=1440,max_outputs=1");
	} else {
		try addPair(allocator, &list, "-device", "virtio-gpu-pci,xres=2560,yres=1440,max_outputs=1");
	}

	try addPair(allocator, &list, "-device", "virtio-balloon-pci,free-page-reporting=on");
	try addPair(allocator, &list, "-device", try std.fmt.allocPrint(allocator, "vhost-vsock-pci,guest-cid={d}", .{config.cid}));
	try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=vfs0,path={s}", .{vfs}));
	try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=vfs0,tag=dotfiles");

	if (config.wallpaper_dir.len > 0) {
		try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=wall0,path={s}", .{wall}));
		try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=wall0,tag=wallpaper");
	}
	if (config.state) {
		try addPair(allocator, &list, "-chardev", try std.fmt.allocPrint(allocator, "socket,id=state0,path={s}/state.sock", .{config.dir}));
		try addPair(allocator, &list, "-device", "vhost-user-fs-pci,chardev=state0,tag=yudae-state");
	}
	try addPair(allocator, &list, "-vga", "none");
	try addPair(allocator, &list, "-device", "virtio-rng-pci");
	try addPair(allocator, &list, "-device", "virtio-tablet-pci");
	try addPair(allocator, &list, "-device", "virtio-keyboard-pci");
	try addPair(allocator, &list, "-netdev", try std.fmt.allocPrint(allocator, "stream,id=net0,server=off,addr.type=unix,addr.path={s}/passt.sock", .{config.dir}));
	try addPair(allocator, &list, "-device", "virtio-net-pci,netdev=net0");
	try addPair(allocator, &list, "-qmp", try std.fmt.allocPrint(allocator, "unix:{s},server=on,wait=off", .{qmp}));
	try addPair(allocator, &list, "-qmp", try std.fmt.allocPrint(allocator, "unix:{s},server=on,wait=off", .{display_qmp}));
	try addPair(allocator, &list, "-serial", try std.fmt.allocPrint(allocator, "file:{s}", .{serial}));
	try addPair(allocator, &list, "-monitor", "none");
	try addPair(allocator, &list, "-display", if (config.gl) "dbus,p2p=yes,gl=on" else "dbus,p2p=yes");
	try list.append(allocator, "-no-reboot");

	return list.toOwnedSlice(allocator);
}

fn addPair(allocator: Allocator, list: *std.ArrayList([]const u8), flag: []const u8, value: []const u8) !void {
	try list.append(allocator, flag);
	try list.append(allocator, value);
}
