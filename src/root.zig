const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;

const xev = @import("xev");
const ReadBuffer = xev.ReadBuffer;
const WriteBuffer = xev.WriteBuffer;

const Dispatch = @import("dispatch.zig").Dispatch;
const message = @import("message.zig");
const Dbus = @import("dbus.zig").Dbus;
const Message = message.Message;
const ObjectPath = @import("types.zig").ObjectPath;

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

    var ntfr: Notifier = .{};
    const notifier = Dispatch(Notifier).bind(&ntfr);

    var dbus = try Dbus.init(allocator);
    defer dbus.deinit();

    dbus.method_call_callback = methodCallCallback;
    dbus.method_return_callback = methodReturnCallback;
    dbus.signal_callback = signalCallback;

    try dbus.start();
    try notifier.register(&dbus);

    const start_time = try Instant.now();
    try dbus.run(.until_done);
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("{d:.2} seconds", .{elapsed / 1e9});
}

const Notifier = struct {
    name: []const u8 = "net.anunknownalias.Dbuz",

    const t = "this";

    pub fn notify(
        self: *@This(),
        // path: ObjectPath,
    ) void {
        const path: ObjectPath = .{ .inner = "/net/anunknownalias/Dbuz" };
        std.debug.print("some stuff {s}, {s}\n", .{self.name, path.inner});
    }

    pub fn notify2(
        self: *@This(),
        // path: ObjectPath,
    ) void {
        const path: ObjectPath = .{ .inner = "/net/anunknownalias/Dbuz" };
        std.debug.print("some stuff {s}, {s}\n", .{self.name, path.inner});
    }
};

fn methodCallCallback(
    bus: *Dbus,
    m: Message,
    wrapper: ?*const anyopaque,
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
            break :blk v.values.items;
        } else unreachable;
    };

    _ = wrapper;
    // if (wrapper) |w| {
    //     const wrap: *Wrap(Notifier) = @alignCast(@ptrCast(@constCast(w)));
    //     wrap.methodCallCallback(bus, m);
    // }

    // const arg1 = blk: {
    //     if (m.values) |v| {
    //         break :blk v.values.items[1].inner.uint32;
    //     } else break :blk 0;
    // };

    std.log.debug("method call received: {any}", .{arg0});

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
    _: ?*const anyopaque,
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
    _: ?*const anyopaque,
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
    _ = @import("dispatch.zig");
}
