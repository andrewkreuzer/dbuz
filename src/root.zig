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

pub const message = @import("message.zig");
pub const BusInterface = @import("interface.zig").BusInterface;
pub const Dbus = @import("dbus.zig").Dbus;
pub const Message = message.Message;
pub const ObjectPath = @import("types.zig").ObjectPath;

// pub fn eventLoop() !void {
//     try runServer();
// }

// const Notifier = struct {
//     path: []const u8 = "/net/anunknownalias/Dbuz",

//     pub fn note(_: *@This()) u32 {
//         return 42;
//     }

//     pub fn notify(
//         _: *@This(),
//         a: u32,
//     ) !u32 {
//         return a;
//     }

//     pub fn notify2(
//         _: *@This(),
//         a: u8,
//         b: u16,
//         c: u8,
//     ) void {
//         std.debug.print("a: {d}, b: {d}, c: {d}\n", .{a, b, c});
//     }

//     pub fn notify3(
//         _: *@This(),
//         _: u8,
//     ) extern struct { a: u32, b: u8, c: extern struct { d: u64, e: bool }, f: [2]u16 } {
//         return .{ .a = 7, .b = 8, .c = .{ .d = 9, .e = true }, .f = [2]u16{1, 2} };
//     }

//     pub fn notify4(
//         _: *@This(),
//         a: extern struct { a: u32, b: u8, c: extern struct { d: u64, e: bool }, f: [2]extern struct{ g: u16, h: u64 } },
//     ) void {
//         assert(a.c.e);
//     }
// };

// pub fn runServer() !void {
//     var gpa = std.heap.DebugAllocator(.{}).init;
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     // const socket_path = "/tmp/dbuz-test/dbuz.sock";
//     var dbus = try Dbus.init(allocator, null);
//     defer dbus.deinit();

//     dbus.read_callback = struct {
//         fn f(bus: *Dbus, msg: *Message) void {
//             if (msg.member) |member| {
//                 if (std.mem.eql(u8, member, "Shutdown")) {
//                     var shutdown_msg = Message.init(.{
//                         .msg_type = .method_return,
//                         .destination = msg.sender,
//                         .sender = msg.destination,
//                         .reply_serial = msg.header.serial,
//                         .flags = 0x01,
//                     });
//                     defer shutdown_msg.deinit(bus.allocator);
//                     bus.writeMsg(&shutdown_msg) catch std.posix.exit(1);
//                     bus.shutdown();
//                 }
//             }
//         }
//     }.f;

//     var notifier: Notifier = .{};
//     const notifier_iface = BusInterface(Notifier).init(&notifier);
//     dbus.bind("net.anunknownalias.Notifier", notifier_iface.interface());

//     log.debug("starting dbus", .{});
//     try dbus.startServer();

//     const start_time = try Instant.now();
//     try dbus.run(.until_done);
//     const end_time = try Instant.now();

//     const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
//     std.log.info("total time {d:.2} seconds", .{elapsed / 1e9});
// }

// const CompletionPool = MemoryPool(xev.Completion);
// const MessagePool = MemoryPool(Message);

// pub fn runClient() !void {
//     var gpa = std.heap.DebugAllocator(.{}).init;
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     var dbus = try Dbus.init(allocator, null);
//     defer dbus.deinit();

//     log.debug("starting dbus client", .{});
//     try dbus.startClient();

//     var completion_pool = CompletionPool.init(allocator);

//     const t1 = try Instant.now();
//     const msg_count = 10 * 1000;
//     for (0..msg_count) |i| {
//         var msg = Message.init(.{
//             .msg_type = .method_call,
//             .path = "/net/anunknownalias/Notifier",
//             .interface = "net.anunknownalias.Notifier",
//             .destination = "net.anunknownalias.Notifier",
//             .member = "Notify",
//             .flags = 0x04,
//             .signature = "u",
//         });

//         try msg.appendNumber(allocator, @as(u32, @intCast(i)));

//         try dbus.writeMsg(&msg);
//         msg.deinit(allocator);
//         try dbus.run(.once);
//     }

//     const t2 = try Instant.now();

//     while (msg_read < msg_count) {
//         const c_ = try completion_pool.create();
//         dbus.read(c_, readCallback);
//         try dbus.run(.once);
//     }

//     const t3 = try Instant.now();

//     completion_pool.deinit();

//     const read_time = @as(f64, @floatFromInt(t2.since(t1)));
//     const write_time = @as(f64, @floatFromInt(t3.since(t2)));
//     const total_time = @as(f64, @floatFromInt(t3.since(t1)));
//     std.debug.print("client completed {d} msgs\n", .{msg_read});
//     std.debug.print("client read time {d:.2} seconds\n", .{read_time / 1e9});
//     std.debug.print("client read msg/s {d:.2}\n", .{msg_count / (read_time / 1e9)});
//     std.debug.print("client write time {d:.2} seconds\n", .{write_time / 1e9});
//     std.debug.print("client write msg/s {d:.2}\n", .{msg_count / (write_time / 1e9)});
//     std.debug.print("client total time {d:.2} seconds\n", .{total_time / 1e9});
//     std.debug.print("client total msg/s {d:.2}\n", .{msg_count / (total_time / 1e9)});
// }

// var msg_read: u32 = 0;

// fn readCallback(
//     bus_: ?*Dbus,
//     _: *xev.Loop,
//     c: *xev.Completion,
//     _: xev.TCP,
//     b: xev.ReadBuffer,
//     r: xev.ReadError!usize,
// ) xev.CallbackAction {
//     const n = r catch |err| switch (err) {
//         error.EOF => return .disarm,
//         else => {
//             log.err("client read err: {any}", .{err});
//             return .disarm;
//         }
//     };

//     var fbs = std.io.fixedBufferStream(b.slice[0..n]);
//     while (true) {
//         var msg = Message.decode(bus_.?.allocator, fbs.reader()) catch |err| switch (err) {
//             error.EndOfStream => break,
//             error.InvalidFields => {
//                 std.debug.print("buf slice: {s}\n", .{b.slice[0..n]});
//                 return .disarm;
//             },
//             else => {
//                 log.err("client read err: {any}", .{err});
//                 return .disarm;
//             },
//         };

//         switch (msg.header.msg_type) {
//             .method_return => {
//                 if (msg.sender) |sender| {
//                     if (!std.mem.eql(u8, sender, "org.freedesktop.DBus")) {
//                         // std.debug.print("method return: {d}\n", .{msg.body_buf.?});
//                     }
//                 }
//             },
//             .@"error" => {
//                 if (msg.signature) |sig| {
//                     std.debug.print("error sig: {s}\n", .{sig});
//                 }
//                 std.debug.print("error: {s}\n", .{msg.body_buf.?});
//             },
//             .signal => {},
//             else => {
//                 std.debug.print("unexpected msg: {s}\n", .{msg.body_buf.?});
//             },
//         }
//         msg_read += 1;
//         msg.deinit(bus_.?.allocator);
//     }
//     bus_.?.completion_pool.destroy(c);
//     return .disarm;
// }

test {
    const builtin = @import("builtin");
    _ = @import("message.zig");

    switch (builtin.os.tag) {
        .linux => {
            _ = @import("dbus.zig");
            _ = @import("interface.zig");
        },
        else => {} // no support for other OSes yet
    }
}
