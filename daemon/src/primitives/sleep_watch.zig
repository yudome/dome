const std = @import("std");
const inhibit = @import("inhibit.zig");

const Bus = opaque {};
const Message = opaque {};
const Slot = opaque {};
const Error = opaque {};

const Callback = *const fn (?*Message, ?*anyopaque, ?*Error) callconv(.c) c_int;

extern fn sd_bus_open_system(bus: *?*Bus) c_int;
extern fn sd_bus_flush_close_unref(bus: *Bus) *Bus;
extern fn sd_bus_add_match(bus: *Bus, slot: ?*?*Slot, match: [*:0]const u8, callback: Callback, userdata: ?*anyopaque) c_int;
extern fn sd_bus_process(bus: *Bus, ret: ?*?*Message) c_int;
extern fn sd_bus_wait(bus: *Bus, timeout_usec: u64) c_int;
extern fn sd_bus_message_read(message: *Message, signature: [*:0]const u8, ...) c_int;

const match: [*:0]const u8 = "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep',path='/org/freedesktop/login1'";
const why: [*:0]const u8 = "pause the virtual machines";

/// Calls `before` while a logind delay inhibitor holds the host awake, and
/// `after` once it is back, then takes the inhibitor again. Runs forever.
pub fn Watch(comptime Context: type) type {
	return struct {
		context: *Context,
		before: *const fn (*Context) void,
		after: *const fn (*Context) void,
		fd: c_int = -1,

		const Self = @This();

		fn onSignal(message: ?*Message, userdata: ?*anyopaque, _: ?*Error) callconv(.c) c_int {
			const self: *Self = @ptrCast(@alignCast(userdata.?));
			var going: c_int = 0;
			if (sd_bus_message_read(message.?, "b", &going) < 0) return 0;
			if (going != 0) {
				self.before(self.context);
				inhibit.release(self.fd);
				self.fd = -1;
			} else {
				self.after(self.context);
				if (self.fd < 0) self.fd = inhibit.take("sleep", why, "delay");
			}
			return 0;
		}

		pub fn run(self: *Self) void {
			var bus: ?*Bus = null;
			if (sd_bus_open_system(&bus) < 0) return;
			defer _ = sd_bus_flush_close_unref(bus.?);
			if (sd_bus_add_match(bus.?, null, match, onSignal, self) < 0) return;
			self.fd = inhibit.take("sleep", why, "delay");
			while (true) {
				const result = sd_bus_process(bus.?, null);
				if (result < 0) return;
				if (result > 0) continue;
				if (sd_bus_wait(bus.?, std.math.maxInt(u64)) < 0) return;
			}
		}
	};
}
