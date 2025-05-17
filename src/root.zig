const std = @import("std");
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;

const xev = @import("xev");
const ReadBuffer = xev.ReadBuffer;
const WriteBuffer = xev.WriteBuffer;

const message = @import("message.zig");
const Interface = @import("interface.zig").Interface;
const Dbus = @import("dbus.zig").Dbus;
const Message = message.Message;
const ObjectPath = @import("types.zig").ObjectPath;

pub fn eventLoop() !void {
    try run();
}

const Notifier = struct {
    path: []const u8 = "/net/anunknownalias/Dbuz",

    pub fn notify(
        _: *@This(),
    ) error{UnfinishedBusiness}!u8 {
        const path: ObjectPath = .{ .inner = "/net/anunknownalias/Dbuz" };
        std.debug.print("some stuff, {s}\n", .{path.inner});
        return error.UnfinishedBusiness;
    }

    pub fn notify2(
        _: *@This(),
        a: u8,
        b: u16,
        c: u8,
    ) void {
        std.debug.print("a: {d}, b: {d}, c: {d}\n", .{a, b, c});
    }

    pub fn notify3(
        _: *@This(),
        _: u8,
    ) extern struct { a: u32, b: u8, c: extern struct { d: u64, e: bool }, f: [2]u16 } {
        return .{ .a = 7, .b = 8, .c = .{ .d = 9, .e = true }, .f = [2]u16{1, 2} };
    }

    pub fn notify4(
        _: *@This(),
        a: extern struct { a: u32, b: u8, c: extern struct { d: u64, e: bool }, f: [2]u16 },
    ) void {
        assert(a.c.e);
    }
};

pub fn run() !void {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa: GPA = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus = try Dbus.init(allocator);
    defer dbus.deinit();

    var notifier: Notifier = .{};
    const notifier_iface = Interface(Notifier).init(&notifier);
    dbus.bind("net.anunknownalias.Notifier", notifier_iface.interface());

    log.debug("starting dbus", .{});
    try dbus.start();

    const start_time = try Instant.now();
    try dbus.run(.until_done);
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("{d:.2} seconds", .{elapsed / 1e9});
}

// fn methodReturnCallback(
//     _: *Dbus,
//     msg: Message,
// ) void {
//     switch (msg.values.?.values.items[0].inner.uint32) {
//         0x01 => std.log.debug("name request succeded", .{}),
//         0x02 => std.log.debug("name request in queue", .{}),
//         0x03 => std.log.debug("name owned by another service", .{}),
//         0x04 => std.log.debug("name request already owned by this service", .{}),
//         else => unreachable,
//     }
// }

test {
    _ = @import("message.zig");
    _ = @import("interface.zig");
}
