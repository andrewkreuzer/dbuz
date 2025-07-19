const std = @import("std");
const log = std.log;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const xev = @import("xev");

const lib = @import("libdbuz");
const BusInterface = lib.BusInterface;
const Dbus = lib.Dbus;
const Message = lib.Message;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var thread_pool = xev.ThreadPool.init(.{});
    var dbus = try Dbus(.client).init(allocator, &thread_pool, null);
    defer dbus.deinit();

    dbus.read_callback = readCallback;

    try dbus.start(.{.start_read = true});

    var life = Message.init(.{
        .msg_type = .method_call,
        .path = "/com/example/Guide",
        .interface = "com.example.Guide",
        .destination = "com.example.Guide",
        .member = "Life",
        .flags = 0x04,
    });

    var hack = Message.init(.{
        .msg_type = .method_call,
        .path = "/com/example/Planet",
        .interface = "com.example.Planet",
        .destination = "com.example.Planet",
        .member = "Hack",
        .flags = 0x04,
    });

    try dbus.writeMsg(&life);
    defer life.deinit(allocator);
    try dbus.writeMsg(&hack);
    defer hack.deinit(allocator);

    try dbus.run(.once);
    try dbus.run(.once);
    try dbus.run(.once);

    try dbus.shutdown();
    try dbus.run(.until_done);
}

// TODO: Implement the client side generation of interfaces
// const Guide = struct {
//     pub fn life( _: *@This()) !u32 {
//         return 42;
//     }
// };
// const Planet = struct {
//     pub fn hack( _: *@This()) !bool {
//         return true;
//     }
// };

fn readCallback(_: *Dbus(.client), msg: *Message) void {
    const ret = msg.values.?.get(0).?.inner;
    switch (ret) {
        .uint32 => |value| std.debug.print("Received uint32: {d}\n", .{value}),
        .boolean => |value| std.debug.print("Received boolean: {any}\n", .{value}),
        else => {},
    }
}
