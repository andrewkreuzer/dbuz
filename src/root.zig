const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;

const xev = @import("xev");
const ReadBuffer = xev.ReadBuffer;
const WriteBuffer = xev.WriteBuffer;

const message = @import("message.zig");
const Dbus = @import("dbus.zig").Dbus;
const Message = message.Message;

pub const NUM_PINGS = 1000;

pub fn eventLoop() !void {
    try run();
}

pub fn run() !void {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa: GPA = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus = try Dbus.init(allocator);
    defer dbus.deinit();

    dbus.method_return_callback = methodReturnCallback;
    dbus.method_call_callback = methodCallCallback;
    dbus.signal_callback = signalCallback;

    try dbus.start();
    try dbus.requestName("net.anunknownalias.Dbuz");
    try dbus.requestName("net.anunknownalias.Notify");
    try dbus.requestName("net.anunknownalias.Shutdown");

    const start_time = try Instant.now();
    try loop.run(.until_done);
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("{d:.2} seconds", .{elapsed / 1e9});
}

fn methodCallCallback(
    bus: *Dbus,
    m: Message,
) void {
    var msg = Message.init(.{
        .msg_type = .method_return,
        .destination = m.sender,
        .sender = m.destination,
        .reply_serial = m.header.serial,
        .flags = 0x01,
    });

    if (mem.eql(u8, m.member.?, "Shutdown")) {
        bus.writeMsg(&msg, null) catch unreachable;
        bus.shutdown();
        return;
    }

    const arg0 = blk: {
        if (m.values) |v| {
            break :blk v.values.items[0].inner.array.get(1).?.inner.@"struct".get(0).?.inner.string;
        } else unreachable;
    };

    // const arg1 = blk: {
    //     if (m.values) |v| {
    //         break :blk v.values.items[1].inner.uint32;
    //     } else break :blk 0;
    // };

    std.log.debug("method call received: {s}", .{arg0});

    msg.signature = "su"; // TODO: generate, track if allocated?
    msg.appendString(bus.allocator, .string, "HI") catch |err| {
        std.log.debug("failed to append value: {any}", .{err});
        return;
    };
    msg.appendInt(bus.allocator, .uint32, 128) catch |err| {
        std.log.debug("failed to append value: {any}", .{err});
        return;
    };

    bus.writeMsg(&msg, null) catch {
        std.log.debug("failed to write message", .{});
    };
}

fn methodReturnCallback(
    _: *Dbus,
    msg: Message,
) void {
    switch (msg.values.?.values.items[0].inner.uint32) {
        0x01 => std.log.debug("name request succeded", .{}),
        0x02 => std.log.debug("name request in queue", .{}),
        0x03 => std.log.debug("name owned by another service", .{}),
        0x04 => std.log.debug("name request already owned by this service", .{}),
        else => unreachable,
    }
}

fn signalCallback(
    _: *Dbus,
    _: Message,
) void {
    std.log.debug("signal received", .{});
}

fn noop(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    return .disarm;
}

test {
    _ = @import("message.zig");
    _ = @import("bind.zig");
}
