const std = @import("std");
const log = std.log;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const MemoryPool = std.heap.MemoryPool;
const Thread = std.Thread;

const xev = @import("xev");

const lib = @import("libdbuz");
const message = lib.message;
const BusInterface = lib.BusInterface;
const Dbus = lib.Dbus;
const Message = message.Message;

pub const std_options: std.Options = .{
    .log_level = .err,
};

const MSG_COUNT = 10 * 1000;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var server_thread_pool = xev.ThreadPool.init(.{});
    var server = try Server.init(allocator, &server_thread_pool);
    defer server.dbus.deinit();
    const t = try Thread.spawn(.{}, Server.mainThread, .{&server});

    var c: xev.Completion = undefined;
    server.main_async.wait(&loop, &c, Server, &server, mainAsyncCallback);

    try loop.run(.until_done);
    t.join();
}

fn mainAsyncCallback(
    s: ?*Server,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    Client.run() catch |err| {
        log.err("client run error: {any}", .{err});
    };
    s.?.dbus.shutdown_async.notify() catch |err| {
        log.err("shutdown notify error: {any}", .{err});
    };

    return .disarm;
}

const CompletionPool = MemoryPool(xev.Completion);

const Bench = struct {
    name: []const u8 = "com.dbuz.Bench",
    pub fn run( _: *@This()) !u32 {
        return 42;
    }
};

const Server = struct {
    dbus: Dbus(.server),
    main_async: xev.Async,

    fn init(allocator: Allocator, thread_pool: *xev.ThreadPool) !Server {
        return .{
            .dbus = try Dbus(.server).init(.{
                .allocator = allocator,
                .thread_pool = thread_pool,
            }),
            .main_async = try xev.Async.init(),
        };
    }

    pub fn mainThread(self: *Server) !void {
        var notifier: Bench = .{};
        const notifier_iface = BusInterface(@TypeOf(self.dbus), Bench).init(&notifier);
        try self.dbus.bind(notifier_iface.interface());

        std.debug.print("starting dbus server\n", .{});
        try self.dbus.start(.{});

        try self.main_async.notify();
        try self.dbus.run(.until_done);
    }
};

const Client = struct {
    fn run() !void {
        var gpa = std.heap.DebugAllocator(.{}).init;
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var thread_pool = xev.ThreadPool.init(.{});
        var dbus = try Dbus(.client).init(.{
            .allocator = allocator,
            .thread_pool = &thread_pool
        });
        defer dbus.deinit();

        std.debug.print("starting dbus client\n", .{});
        try dbus.start(.{});

        var completion_pool = CompletionPool.init(allocator);
        defer completion_pool.deinit();

        const t1 = try Instant.now();
        for (0..MSG_COUNT) |_| {
            var msg = Message.init(.{
                .msg_type = .method_call,
                .path = "/com/dbuz/Bench",
                .interface = "com.dbuz.Bench",
                .destination = "com.dbuz.Bench",
                .member = "Run",
                .flags = 0x04,
            });

            try dbus.writeMsg(&msg);
            msg.deinit(allocator);
            try dbus.run(.once);
        }

        const t2 = try Instant.now();

        while (msg_read < MSG_COUNT) {
            const c = try completion_pool.create();
            dbus.read(c, readCallback);
            try dbus.run(.once);
        }
        const t3 = try Instant.now();

        try dbus.shutdown();
        try dbus.run(.until_done);

        const write_time = @as(f64, @floatFromInt(t2.since(t1)));
        const read_time = @as(f64, @floatFromInt(t3.since(t2)));
        const total_time = @as(f64, @floatFromInt(t3.since(t1)));
        std.debug.print("\n", .{});
        std.debug.print("client completed {d} msgs\n", .{msg_read});
        std.debug.print("client write time {d:.2} seconds\n", .{write_time / 1e9});
        std.debug.print("client write msg/s {d:.2}\n", .{MSG_COUNT / (write_time / 1e9)});
        std.debug.print("client read time {d:.2} seconds\n", .{read_time / 1e9});
        std.debug.print("client read msg/s {d:.2}\n", .{MSG_COUNT / (read_time / 1e9)});
        std.debug.print("client total time {d:.2} seconds\n", .{total_time / 1e9});
        std.debug.print("client total msg/s {d:.2}\n", .{MSG_COUNT / (total_time / 1e9)});
    }

    var msg_read: u32 = 0;

    fn readCallback(
        bus_: ?*Dbus(.client),
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
                    log.err("buf slice: {s}\n", .{b.slice[0..n]});
                    return .disarm;
                },
                else => {
                    log.err("client read err: {any}", .{err});
                    return .disarm;
                },
            };

            switch (msg.header.msg_type) {
                .method_return => {
                    if (msg.sender) |sender| {
                        if (!mem.eql(u8, sender, "org.freedesktop.DBus")) {
                            // std.debug.print("method return: {d}\n", .{msg.body_buf.?});
                        }
                    }
                },
                .@"error" => {
                    if (msg.signature) |sig| {
                        log.err("error sig: {s}\n", .{sig});
                    }
                    log.err("error: {s}\n", .{msg.body_buf.?});
                },
                .signal => {},
                else => {
                    log.err("unexpected msg: {s}\n", .{msg.body_buf.?});
                },
            }
            msg_read += 1;
            msg.deinit(bus_.?.allocator);
        }
        bus_.?.completion_pool.destroy(c);
        return .disarm;
    }
};
