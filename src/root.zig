const std = @import("std");
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const MemoryPool = std.heap.MemoryPool;

const xev = @import("xev");
const ReadBuffer = xev.ReadBuffer;
const WriteBuffer = xev.WriteBuffer;

const message = @import("message.zig");
const Interface = @import("interface.zig").Interface;
const Dbus = @import("dbus.zig").Dbus;
const Message = message.Message;
const ObjectPath = @import("types.zig").ObjectPath;

pub fn eventLoop() !void {
    try runServer();
}

const Notifier = struct {
    path: []const u8 = "/net/anunknownalias/Dbuz",

    pub fn notify(
        _: *@This(),
        a: u8,
    ) !u8 {
        return a;
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

pub fn runServer() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus = try Dbus.init(allocator, true);
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
                    defer shutdown_msg.deinit(bus.allocator);
                    bus.writeMsg(&shutdown_msg) catch std.posix.exit(1);
                    bus.shutdown();
                }
            }
        }
    }.f;

    var notifier: Notifier = .{};
    const notifier_iface = Interface(Notifier).init(&notifier);
    dbus.bind("net.anunknownalias.Notifier", notifier_iface.interface());

    log.debug("starting dbus", .{});
    try dbus.startServer();

    const start_time = try Instant.now();
    try dbus.run(.until_done);
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("total time {d:.2} seconds", .{elapsed / 1e9});
}

const CompletionPool = MemoryPool(xev.Completion);
const MessagePool = MemoryPool(Message);

pub fn runClient() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus = try Dbus.init(allocator, false);
    defer dbus.deinit();

    log.debug("starting dbus client", .{});
    try dbus.startClient();

    var completion_pool = CompletionPool.init(allocator);

    const msg_count = 10;
    for (0..msg_count) |i| {
        var msg = Message.init(.{
            .msg_type = .method_call,
            .path = "/net/anunknownalias/Notifier",
            .interface = "net.anunknownalias.Notifier",
            .destination = "net.anunknownalias.Notifier",
            .member = "Notify",
            .flags = 0x04,
            .signature = "y",
        });
        defer msg.deinit(allocator);

        try msg.appendNumber(allocator, @as(u8, @intCast(i)));

        try dbus.writeMsg(&msg);
    }

    while (msg_read < msg_count) {
        const c_ = try completion_pool.create();
        dbus.read(c_, readCallback);
        try dbus.run(.until_done);
    }

    completion_pool.deinit();
    std.debug.print("client done\n", .{});
}

var msg_read: u8 = 0;

fn readCallback(
    bus_: ?*Dbus,
    _: *xev.Loop,
    c: *xev.Completion,
    _: xev.TCP,
    b: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const n = r catch |err| switch (err) {
        error.EOF => return .disarm,
        else => {
            log.err("client read err: {any}", .{err});
            return .disarm;
        }
    };

    var fbs = std.io.fixedBufferStream(b.slice[0..n]);
    while (true) {
        var msg = Message.decode(bus_.?.allocator, fbs.reader()) catch |err| switch (err) {
            error.EndOfStream => break,
            error.InvalidFields => {
                std.debug.print("buf slice: {s}\n", .{b.slice[0..n]});
                return .disarm;
            },
            else => {
                log.err("client read err: {any}", .{err});
                return .disarm;
            },
        };
        defer msg.deinit(bus_.?.allocator);

        switch (msg.header.msg_type) {
            .method_return => {
                if (msg.sender) |sender| {
                    if (!std.mem.eql(u8, sender, "org.freedesktop.DBus")) {
                        std.debug.print("method return: {d}\n", .{msg.body_buf.?});
                    }
                }
            },
            .@"error" => {
                if (msg.signature) |sig| {
                    std.debug.print("error sig: {s}\n", .{sig});
                }
                std.debug.print("error: {s}\n", .{msg.body_buf.?});
            },
            .signal => {},
            else => {
                std.debug.print("unexpected msg: {s}\n", .{msg.body_buf.?});
            },
        }
        msg_read += 1;
    }
    bus_.?.completion_pool.destroy(c);
    std.debug.print("client completed read\n", .{});
    return .disarm;
}

test {
    _ = @import("message.zig");
    _ = @import("interface.zig");
}
