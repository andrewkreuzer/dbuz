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

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var server = try Server.init(allocator);
    const t = try Thread.spawn(.{}, Server.mainThread, .{&server});

    var c: xev.Completion = undefined;
    server.main_async.wait(&loop, &c, Server, &server, mainAsyncCallback);

    try loop.run(.once);
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
    s.?.shutdown_async.notify() catch |err| {
        log.err("shutdown notify error: {any}", .{err});
    };

    return .disarm;
}

const CompletionPool = MemoryPool(xev.Completion);

const Bench = struct {
    pub fn run( _: *@This(), _: u32) !u32 {
        return 42;
    }
};

const Server = struct {
    dbus: Dbus,
    main_async: xev.Async,
    shutdown_async: xev.Async,

    fn init(allocator: Allocator) !Server {
        return .{
            .dbus = try Dbus.init(allocator, null),
            .main_async = try xev.Async.init(),
            .shutdown_async = try xev.Async.init(),
        };
    }

    pub fn mainThread(self: *Server) !void {
        var notifier: Bench = .{};
        const notifier_iface = BusInterface(Bench).init(&notifier);
        self.dbus.bind("com.dbuz.Bench", notifier_iface.interface());

        const c = try self.dbus.completion_pool.create();
        self.shutdown_async.wait(&self.dbus.loop, c, Server, self, shutdownAsyncCallback);
        try self.dbus.run(.no_wait);

        try self.dbus.startServer();
        try self.main_async.notify();
        try self.dbus.run(.until_done);
    }

    fn shutdownAsyncCallback(
        s: ?*Server,
        _: *xev.Loop,
        c: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        if (s) |server| {
            server.dbus.completion_pool.destroy(c);
            server.dbus.shutdown();
            server.dbus.deinit();
        }
        return .disarm;
    }
};

const Client = struct {
    fn run() !void {
        var gpa = std.heap.DebugAllocator(.{}).init;
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var dbus = try Dbus.init(allocator, null);
        defer dbus.deinit();

        log.info("starting dbus client", .{});
        try dbus.startClient();

        var completion_pool = CompletionPool.init(allocator);
        defer completion_pool.deinit();

        const t1 = try Instant.now();
        const msg_count = 10 * 1000;
        for (0..msg_count) |_| {
            var msg = Message.init(.{
                .msg_type = .method_call,
                .path = "/com/dbuz/Bench",
                .interface = "com.dbuz.Bench",
                .destination = "com.dbuz.Bench",
                .member = "Run",
                .flags = 0x04,
                .signature = "u",
            });

            // TODO: there is a bug when no arguments are sent
            // so for now we just send a number
            try msg.appendNumber(allocator, @as(u32, @intCast(42)));

            try dbus.writeMsg(&msg);
            msg.deinit(allocator);
            try dbus.run(.once);
        }

        const t2 = try Instant.now();

        while (msg_read < msg_count) {
            const c = try completion_pool.create();
            dbus.read(c, readCallback);
            try dbus.run(.once);
        }
        const t3 = try Instant.now();

        dbus.shutdown();
        try dbus.run(.until_done);

        const write_time = @as(f64, @floatFromInt(t2.since(t1)));
        const read_time = @as(f64, @floatFromInt(t3.since(t2)));
        const total_time = @as(f64, @floatFromInt(t3.since(t1)));
        std.debug.print("client completed {d} msgs\n", .{msg_read});
        std.debug.print("client write time {d:.2} seconds\n", .{write_time / 1e9});
        std.debug.print("client write msg/s {d:.2}\n", .{msg_count / (write_time / 1e9)});
        std.debug.print("client read time {d:.2} seconds\n", .{read_time / 1e9});
        std.debug.print("client read msg/s {d:.2}\n", .{msg_count / (read_time / 1e9)});
        std.debug.print("client total time {d:.2} seconds\n", .{total_time / 1e9});
        std.debug.print("client total msg/s {d:.2}\n", .{msg_count / (total_time / 1e9)});
    }

    var msg_read: u32 = 0;

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
            msg.deinit(bus_.?.allocator);
        }
        bus_.?.completion_pool.destroy(c);
        return .disarm;
    }
};
