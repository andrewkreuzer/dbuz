const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const log = std.log;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MemoryPool = std.heap.MemoryPool;
const StringHashMap = std.StringHashMap;

const xev = @import("xev");
// just treat it as a TCP socket
const Unix = xev.TCP;

const interface = @import("interface.zig");
const message = @import("message.zig");
const Hello = message.Hello;
const Interface = interface.Interface;
const Message = message.Message;
const Value = message.Value;

// TODO:
// maximum size of a dbus message is 128MiB
const MAX_BUFFER_SIZE = 128 * 1024;
const BufferPool = MemoryPool([MAX_BUFFER_SIZE]u8);
const CompletionPool = MemoryPool(xev.Completion);
const WriteRequestPool = MemoryPool(xev.WriteRequest);

pub const Dbus = struct {
    uid: u32 = 0,
    name: ?[]const u8 = null,
    server_address: ?[]const u8 = undefined,

    loop: xev.Loop,
    thread_pool: xev.ThreadPool,
    completion_pool: CompletionPool,
    read_completion: xev.Completion = undefined,
    write_queue: xev.WriteQueue = .{},
    write_request_pool: WriteRequestPool,

    socket: ?Unix = null,
    path: []const u8,
    msg_serial: u32 = 1, // TODO: should this be per sender, not per bus?

    allocator: Allocator,
    // TODO:
    // I've solved having to deal with a partial msg
    // in a full buffer by simple making a bigger buffer
    // so that never happens 🫤. Although this isn't
    // even the dbus max message size...
    // 2 to the 27th power or 134217728 (128 MiB)
    read_buffer: [MAX_BUFFER_SIZE]u8 = undefined,
    write_buffer_pool: BufferPool,

    state: State,

    interfaces: StringHashMap(Interface) = undefined,
    read_callback: ?*const fn (bus: *Dbus, msg: *Message) void = null,
    write_callback: ?*const fn (bus: *Dbus) void = null,

    const State = enum {
        disconnected,
        connecting,
        connected,
        authenticating,
        authenticated,
        ready,
    };

    pub fn init(allocator: Allocator, path: ?[]const u8) !Dbus {
        const uid = blk: {
            const u = std.os.linux.getuid();
            if (u == 0) {
                // we are root, so we'll drop to connect to the session bus
                // really only included to test with perf
                try std.posix.setuid(1000);
                break :blk std.os.linux.getuid();
            } else {
                break :blk u;
            }
        };

        // io_uring doesn't need a thread pool,
        // but we'll add one for other backends
        var thread_pool = xev.ThreadPool.init(.{});

        return .{
            .uid = uid,
            .loop = try xev.Loop.init(.{
                .thread_pool = &thread_pool,
                .entries = std.math.pow(u13, 2, 12),
            }),
            .thread_pool = thread_pool,
            .completion_pool = CompletionPool.init(allocator),
            .write_request_pool = WriteRequestPool.init(allocator),
            .path = if (path) |p| p else defaultSocketPath(uid),
            .allocator = allocator,
            .write_buffer_pool = BufferPool.init(allocator),
            .state = .disconnected,
            .interfaces = StringHashMap(Interface).init(allocator),
        };
    }

    pub fn deinit(bus: *Dbus) void {
        if (bus.name) |name| bus.allocator.free(name);
        bus.loop.stop();
        bus.loop.deinit();
        bus.thread_pool.shutdown();
        bus.thread_pool.deinit();
        bus.interfaces.deinit();
        bus.write_request_pool.deinit();
        bus.write_buffer_pool.deinit();
        bus.completion_pool.deinit();
    }

    pub fn bind(bus: *Dbus, name: []const u8, iface: Interface) void {
        bus.interfaces.put(name, iface) catch unreachable;
    }

    pub fn defaultSocketPath(uid: u32) []const u8 {
        return blk: {
            if (posix.getenv("DBUS_SESSION_BUS_ADDRESS")) |p| {
                var iter = std.mem.splitSequence(u8, p, "=");
                _ = iter.first(); // ignore transport name, and path key
                break :blk iter.next().?;
            } else {
                assert(uid != 0);
                var path_buf: [256]u8 = undefined;
                break :blk std.fmt.bufPrint(
                   &path_buf,
                   "/run/user/{d}/bus",
                   .{uid},
               ) catch unreachable;
            }
        };
    }

    pub fn startClient(bus: *Dbus) !void {
        try bus.connect();
        try bus.authenticate();
        try bus.hello();
    }

    pub fn startServer(bus: *Dbus) !void {
        try bus.connect();
        try bus.authenticate();
        try bus.hello();
        try bus.requestBoundNames();
        bus.read(null, null);
        assert(bus.state == .ready);
        assert(bus.loop.active == 1);
    }

    pub fn startServerWithName(bus: *Dbus, name: []const u8) !void {
        try bus.connect();
        try bus.authenticate();
        try bus.hello();
        try bus.requestName(name);
        bus.read(null, null);
    }

    pub fn run(bus: *Dbus, mode: xev.RunMode) !void {
        try bus.loop.run(mode);
    }

    pub fn disconnected(bus: *Dbus) bool {
        return bus.state == .disconnected;
    }

    pub fn connect(bus: *Dbus) !void {
        const addr = try std.net.Address.initUnix(bus.path);
        bus.socket = try Unix.init(addr);

        assert(bus.socket != null);
        if (!xev.dynamic) assert(bus.socket.?.fd != -1);
        assert(bus.state == .disconnected);
        bus.state = .connecting;

        var c: xev.Completion = undefined;
        bus.socket.?.connect(&bus.loop, &c, addr, Dbus, bus, onConnect);
        try bus.loop.run(.once);
        assert(bus.state == .connected);
        assert(bus.loop.active == 0);
    }

    fn onConnect(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        r: xev.ConnectError!void,
    ) xev.CallbackAction {
        const bus = bus_.?;
        _ = r catch |err| {
            log.err("client connect err: {any}", .{err});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        };

        assert(bus.socket != null);
        assert(bus.state == .connecting);
        bus.state = .connected;

        return .disarm;
    }

    pub fn authenticate(bus: *Dbus) !void {
        assert(bus.socket != null);
        assert(bus.state == .connected);
        bus.state = .authenticating;

        const uid = std.os.linux.getuid();
        var uid_buf: [6]u8 = undefined;
        const uid_str = try std.fmt.bufPrint(
            &uid_buf,
            "{d}",
            .{uid}
        );

        var buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buf,
            "\x00AUTH EXTERNAL {x}\r\n",
            .{std.fmt.fmtSliceHexLower(uid_str)}
        );

        bus.write(msg, onAuthWrite);
        try bus.loop.run(.once); // write auth
        try bus.loop.run(.once); // read response
        try bus.loop.run(.once); // write begin
        assert(bus.state == .authenticated);
        assert(bus.loop.active == 0);
    }

    fn onAuthWrite(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const bus = bus_.?;
        _ = r catch |err| {
            log.err("client auth write err: {any}", .{err});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        };

        assert(bus.state == .authenticating or bus.state == .authenticated);
        if (bus.state == .authenticated) return .disarm;

        bus.read(c, onAuthRead);

        return .disarm;
    }

    fn onAuthRead(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        b: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const bus = bus_.?;
        const n = r catch |err| {
            log.err("client auth read err: {any}", .{err});
            return .disarm;
        };

        const slice = b.slice[0..n];

        if (bus.state != .authenticating) {
            log.err("client auth read unexpected state: {any}", .{bus.state});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        }

        var iter = std.mem.splitScalar(u8, slice, ' ');
        const ok = ok: {
            const first = iter.first();
            if (std.mem.eql(u8, first, "OK")) {
                break :ok true;
            } else if (std.mem.eql(u8, first, "REJECTED")) {
                break :ok false;
            } else {
                log.err("client auth error: {s}", .{slice});
                socket.shutdown(l, c, Dbus, bus, onShutdown);
                return .disarm;
            }
        };

        if (!ok) {
            log.err("client auth rejected: {s}", .{slice});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        }

        bus.server_address = iter.next() orelse unreachable;
        bus.state = .authenticated;
        bus.write("BEGIN\r\n", onAuthWrite);
        return .disarm;
    }

    pub fn hello(bus: *Dbus) !void {
        assert(bus.state == .authenticated);
        var msg = Hello;
        defer msg.deinit(bus.allocator);

        msg.header.serial = bus.msg_serial;
        bus.msg_serial += 1;

        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        try msg.encode(bus.allocator, writer);

        bus.write(fbs.getWritten(), onHelloWrite);
        try bus.loop.run(.once); // write hello
        try bus.loop.run(.once); // read hello response
        assert(bus.state == .ready);
        assert(bus.loop.active == 0);
    }

    fn onHelloWrite(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const bus = bus_.?;
        _ = r catch |err| {
            log.err("client hello write err: {any}", .{err});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        };

        bus.read(c, onHelloRead);
        return .disarm;
    }

    fn onHelloRead(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        b: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        var bus = bus_.?;
        const n = r catch |err| {
            log.err("client hello read err: {any}", .{err});
            return .disarm;
        };

        var fbs = std.io.fixedBufferStream(b.slice[0..n]);
        const reader = fbs.reader();
        var msg = Message.decode(bus.allocator, reader) catch {
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        };
        defer msg.deinit(bus.allocator);

        bus.name = bus.allocator.dupe(
            u8, msg.values.?.values.getLast().inner.string.inner
        ) catch unreachable;

        bus.state = .ready;
        return .disarm;
    }

    fn requestBoundNames(
        bus: *Dbus,
    ) !void {
        if (bus.interfaces.count() == 0) return;
        var iter = bus.interfaces.keyIterator();
        while (iter.next()) |name| {
            try bus.requestName(name.*);
        }
    }

    pub fn requestName(bus: *Dbus, name: []const u8) !void {
        log.info("requesting name: {s}", .{name});
        var msg = message.RequestName;
        defer msg.deinit(bus.allocator);
        try msg.appendString(bus.allocator, .string, name);
        try msg.appendNumber(bus.allocator, @as(u32, 1));

        try bus.writeMsg(&msg);
        bus.read(null, struct {
            fn cb(
                bus_: ?*Dbus,
                _: *xev.Loop,
                _: *xev.Completion,
                _: Unix,
                b: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction {
                const n = r catch |err| switch (err) {
                    error.EOF => return .disarm,
                    else => {
                        log.err("client request name read err: {any}", .{err});
                        return .disarm;
                    },
                };
                if (n < Message.MinimumSize) {
                    log.err("client request name read: to few bytes {d}/{d} of minimum message size", .{n, Message.MinimumSize});
                    return .disarm;
                }
                var fbs = std.io.fixedBufferStream(b.slice[0..n]);
                while (true) {
                    var msg_ = Message.decode(bus_.?.allocator, fbs.reader()) catch |err| switch (err) {
                        error.EndOfStream => break,
                        error.IncompleteMsg => {
                            log.err("client request name read err: incomplete message", .{});
                            return .disarm;
                        },
                        error.InvalidFields => {
                            log.err("client request name read err: invalid fields: {s}\n", .{b.slice[0..n]});
                            return .disarm;
                        },
                        else => {
                            log.err("client request name read err: {any}", .{err});
                            return .disarm;
                        },
                    };
                    defer msg_.deinit(bus_.?.allocator);

                    if (msg_.header.msg_type == .@"error") {
                        log.err(
                            "client request name read: {s}",
                            .{msg_.values.?.get(0).?.inner.string.inner}
                        );
                    }

                    if (msg_.header.msg_type == .signal) continue;
                    switch (msg_.values.?.get(0).?.inner.uint32) {
                        1 => return .disarm,
                        else => {
                            log.err("client request name read: unexpected reply value: {d}", .{msg_.values.?.get(0).?.inner.uint32});
                            return .disarm;
                        }
                    }
                }
                return .rearm;
            }
        }.cb);
        // TODO: rewrite this function we need to ignore
        // signals and errors and confirm the reply
        // we shouldn't need the third run here
        try bus.run(.once); // write request name
        try bus.run(.once); // read request name response
        try bus.run(.once);
        assert(bus.state == .ready);
        assert(bus.loop.active == 0);
    }

    pub fn writeMsg(bus: *Dbus, msg: *Message) !void {
        // If the serial isn't set to it's default value
        // don't overwrite it with our message counter
        if (msg.header.serial == 1) {
            msg.header.serial = bus.msg_serial;
            bus.msg_serial += 1;
        }

        const buf = try bus.write_buffer_pool.create();
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try msg.encode(bus.allocator, writer);

        const bytes = fbs.getWritten();
        bus.write(bytes, null);
    }

    pub fn read(
        bus: *Dbus,
        c: ?*xev.Completion,
        cb: ?fn(
            ?*Dbus,
            *xev.Loop,
            *xev.Completion,
            Unix,
            xev.ReadBuffer,
            xev.ReadError!usize,
        ) xev.CallbackAction
    ) void {
        assert(bus.socket != null);

        if (@intFromEnum(bus.state)
            < comptime @intFromEnum(State.connected)
        ) {
            log.err("client read: bus is disconnected", .{});
            return;
        }

        assert(@intFromEnum(bus.state)
            > comptime @intFromEnum(State.connected)
        );

        const c_ = c orelse &bus.read_completion;
        bus.socket.?.read(
            &bus.loop,
            c_,
            .{ .slice = &bus.read_buffer },
            Dbus,
            bus,
            cb orelse onRead,
        );
    }

    fn onRead(
        bus_: ?*Dbus,
        _: *xev.Loop,
        _: *xev.Completion,
        _: Unix,
        b: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const bus = bus_.?;
        const n = r catch |err| switch (err) {
            error.EOF => return .disarm,
            else => {
                log.err("client read err: {any}", .{err});
                return .disarm;
            }
        };

        if (n < Message.MinimumSize) {
            log.err("client read: to few bytes {d}/{d} of minimum message size", .{n, Message.MinimumSize});
            return .disarm;
        }

        var fbs = std.io.fixedBufferStream(b.slice[0..n]);
        while (true) {
            var msg = Message.decode(bus.allocator, fbs.reader()) catch |err| switch (err) {
                error.EndOfStream => break,
                error.IncompleteMsg => {
                    log.err("client read: incomplete message", .{});
                    return .disarm;
                },
                error.InvalidFields => {
                    log.err("client read: invalid fields: {s}\n", .{b.slice[0..n]});
                    return .disarm;
                },
                else => {
                    log.err("client read err: {any}", .{err});
                    return .disarm;
                },
            };
            defer msg.deinit(bus.allocator);

            if (msg.header.msg_type == .signal) continue;

            if (bus.read_callback) |cb| cb(bus, &msg);

            if (msg.member == null) continue;
            if (msg.interface) |msg_iface| {
                const iface = bus.interfaces.get(msg_iface);
                if (iface) |i| i.call(bus, &msg);
            }
        }

        return .rearm;
    }

    fn write(
        bus: *Dbus,
        b: []const u8,
        cb: ?fn(
            ?*Dbus,
            *xev.Loop,
            *xev.Completion,
            Unix,
            xev.WriteBuffer,
            xev.WriteError!usize,
        ) xev.CallbackAction
    ) void {
        assert(bus.socket != null);

        if (@intFromEnum(bus.state)
            < comptime @intFromEnum(State.connected)
        ) {
            log.err("client write: bus is disconnected", .{});
            return;
        }
        assert(@intFromEnum(bus.state)
            > comptime @intFromEnum(State.connected)
        );

        const req = bus.write_request_pool.create() catch unreachable;
        bus.socket.?.queueWrite(
            &bus.loop,
            &bus.write_queue,
            req,
            .{ .slice = b },
            Dbus,
            bus,
            cb orelse onWrite,
        );
    }

    fn onWrite(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        b: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const bus = bus_.?;
        _ = r catch |err| {
            log.err("client write err: {any}", .{err});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        };

        if (bus.write_callback) |cb| cb(bus);

        const buf = @as(*align(8) [MAX_BUFFER_SIZE]u8, @alignCast(@ptrCast(@constCast(b.slice))));
        bus.write_buffer_pool.destroy(buf);

        const req = xev.WriteRequest.from(c);
        bus.write_request_pool.destroy(req);

        return .disarm;
    }

    pub fn shutdown(bus: *Dbus) void {
        assert(bus.socket != null);
        assert(@intFromEnum(bus.state) > comptime @intFromEnum(State.connected));
        const c = bus.completion_pool.create() catch unreachable;
        bus.socket.?.shutdown(
            &bus.loop,
            c,
            Dbus,
            bus,
            onShutdown,
        );
    }

    fn onShutdown(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        r: xev.ShutdownError!void,
    ) xev.CallbackAction {
        _ = r catch |err| {
            log.err("dbus shutdown err: {any}", .{err});
        };
        log.debug("dbus shutdown: {any}", .{r});

        const bus = bus_.?;
        socket.close(l, c, Dbus, bus, onClose);
        return .disarm;
    }

    fn onClose(
        bus_: ?*Dbus,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: Unix,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        _ = l;
        _ = socket;
        _ = r catch |err| {
            log.err("client close err: {any}", .{err});
        };
        log.debug("client close: {any}", .{r});

        bus_.?.completion_pool.destroy(c);
        bus_.?.state = .disconnected;
        return .disarm;
    }
};

test "setup and shutdown" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    var server = try Dbus.init(allocator, null);
    defer server.deinit();

    try server.connect();
    try std.testing.expect(server.state == .connected);

    try server.authenticate();
    try std.testing.expect(server.state == .authenticated);

    try server.hello();
    try std.testing.expect(server.state == .ready);

    server.shutdown();
    try server.run(.until_done);
    try std.testing.expect(server.state == .disconnected);
}

test "send msg" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    var server = try Dbus.init(alloc, null);
    defer server.deinit();

    try server.startServerWithName("net.dbuz.test.SendMsg");
    try std.testing.expect(server.state == .ready);

    server.read_callback = struct {
        fn cb(bus: *Dbus, m: *Message) void {
            var echo = m.*;
            defer echo.deinit(bus.allocator);
            echo.header.msg_type = .method_return;
            echo.destination = m.sender;
            echo.sender = m.destination;
            echo.reply_serial = m.header.serial;
            echo.header.flags = 0x01;
            bus.writeMsg(&echo) catch unreachable;
        }
    }.cb;

    var client = try Dbus.init(alloc, null);
    defer client.deinit();
    try client.startClient();
    client.read(null, null);

    client.read_callback = struct {
        fn cb(_: *Dbus, m: *Message) void {
            std.testing.expectEqual(.method_return, m.header.msg_type) catch unreachable;
            std.testing.expectEqualStrings("/net/dbuz/test/SendMsg", m.path.?) catch unreachable;
            std.testing.expectEqualStrings("net.dbuz.test.SendMsg", m.interface.?) catch unreachable;
            std.testing.expectEqualStrings("Test", m.member.?) catch unreachable;
            std.testing.expectEqual(2, m.reply_serial.?) catch unreachable;
        }
    }.cb;

    var msg = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/SendMsg",
        .interface = "net.dbuz.test.SendMsg",
        .destination = "net.dbuz.test.SendMsg",
        .member = "Test",
        .flags = 0x00,
    });
    try client.writeMsg(&msg);
    try client.run(.once);
    msg.deinit(client.allocator);

    // read and write
    try server.run(.once);
    try server.run(.once);

    try client.run(.once);

    server.shutdown();
    server.run(.until_done) catch unreachable;
    try std.testing.expect(server.state == .disconnected);

    client.shutdown();
    client.run(.until_done) catch unreachable;
    try std.testing.expect(client.state == .disconnected);
}
