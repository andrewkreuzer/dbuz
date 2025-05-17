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
    ) !u8 {
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
        a: extern struct { a: u32, b: u8, c: extern struct { d: u64, e: bool }, f: [2]extern struct{ g: u16, h: u64 } },
    ) void {
        assert(a.c.e);
    }
};

pub fn run() !void {
    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa: GPA = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus = try Dbus.init(allocator);
    defer dbus.deinit();

    dbus.read_callback = struct { 
        fn f(bus: *Dbus, msg: *Message) void {
            if (msg.member) |member| {
                if (std.mem.eql(u8, member, "Shutdown")) {
                    var shutdown_msg = Message.init(.{
                        .msg_type = .method_return,
                        .destination = msg.sender,
                        .sender = msg.destination,
                        .reply_serial = msg.header.serial,
                        .flags = 0x01,
                    });
                    bus.writeMsg(&shutdown_msg, null) catch std.posix.exit(1);
                    bus.shutdown();
                }
            }
        }
    }.f;

    var notifier: Notifier = .{};
    const notifier_iface = Interface(Notifier).init(&notifier);
    dbus.bind("net.anunknownalias.Notifier", notifier_iface.interface());

    log.debug("starting dbus", .{});
    try dbus.start();

    const start_time = try Instant.now();
    try dbus.run(.until_done);
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("total time {d:.2} seconds", .{elapsed / 1e9});
}

test {
    _ = @import("message.zig");
    _ = @import("interface.zig");
}
