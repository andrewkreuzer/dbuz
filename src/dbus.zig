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

pub const BusType = enum {
    client,
    server,
};

pub fn Dbus(comptime bus_type: BusType) type {
    return struct {
        type: BusType,

        uid: u32 = 0,
        name: ?[]const u8 = null,
        server_address: ?[]const u8 = undefined,

        loop: xev.Loop,
        thread_pool: ?*xev.ThreadPool,
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
        err: ?anyerror = null,

        interfaces: StringHashMap(Interface(Bus)) = undefined,
        read_callback: ?*const fn (bus: *Bus, msg: *Message) void = null,
        write_callback: ?*const fn (bus: *Bus) void = null,

        name_acquired_signal_received: bool = false,

        const Bus = @This();

        const State = enum {
            shutdown,
            disconnected,
            connecting,
            connected,
            authenticating,
            authenticated,
            ready,
        };

        pub fn init(allocator: Allocator, thread_pool: ?*xev.ThreadPool, path: ?[]const u8) !Bus {
            const uid = std.os.linux.getuid();
            return .{
                .uid = uid,
                .type = bus_type,
                .loop = try xev.Loop.init(.{
                    .thread_pool = thread_pool,
                }),
                .thread_pool = thread_pool,
                .completion_pool = CompletionPool.init(allocator),
                .write_request_pool = WriteRequestPool.init(allocator),
                .path = path orelse defaultSocketPath(uid),
                .allocator = allocator,
                .write_buffer_pool = BufferPool.init(allocator),
                .state = .disconnected,
                .interfaces = StringHashMap(Interface(Bus)).init(allocator),
            };
        }

        pub fn deinit(bus: *Bus) void {
            if (bus.name) |name| bus.allocator.free(name);
            bus.loop.stop();
            bus.loop.deinit();

            if (bus.thread_pool) |pool| {
                pool.shutdown();
                pool.deinit();
            }

            bus.interfaces.deinit();
            bus.write_request_pool.deinit();
            bus.write_buffer_pool.deinit();
            bus.completion_pool.deinit();
        }

        pub fn bind(bus: *Bus, comptime name: []const u8, iface: Interface(Bus)) void {
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

        pub fn startClient(bus: *Bus) !void {
            try bus.connect();
            try bus.authenticate();
            try bus.hello();
        }

        pub fn startServer(bus: *Bus) !void {
            try bus.connect();
            try bus.authenticate();
            try bus.hello();
            try bus.requestBoundNames();
            bus.read(null, null);
            assert(bus.state == .ready);
        }

        pub fn startServerWithName(bus: *Bus, name: []const u8) !void {
            try bus.connect();
            try bus.authenticate();
            try bus.hello();
            try bus.requestName(name);
            bus.read(null, null);
        }

        pub fn run(bus: *Bus, mode: xev.RunMode) !void {
            try bus.loop.run(mode);
        }

        pub fn disconnected(bus: *Bus) bool {
            return bus.state == .disconnected;
        }

        pub fn connect(bus: *Bus) !void {
            const addr = try std.net.Address.initUnix(bus.path);
            bus.socket = try Unix.init(addr);

            assert(bus.socket != null);
            assert(bus.state == .disconnected);
            bus.state = .connecting;

            var c: xev.Completion = undefined;
            bus.socket.?.connect(&bus.loop, &c, addr, Bus, bus, onConnect);
            try bus.run(.once);
            if (bus.err) |e| return e;
        }

        fn onConnect(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            r: xev.ConnectError!void,
        ) xev.CallbackAction {
            const bus = bus_.?;
            _ = r catch |err| {
                log.err("client connect err: {any}", .{err});
                bus.err = err;
                return .disarm;
            };

            assert(bus.socket != null);
            assert(bus.state == .connecting);
            bus.state = .connected;

            return .disarm;
        }

        pub fn authenticate(bus: *Bus) !void {
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
            while (true) {
                if (bus.err) |e| return e;
                switch (bus.state) {
                    .authenticated => break,
                    .authenticating => try bus.loop.run(.once),
                    else => return error.Unexpected,
                }
            }
            assert(bus.state == .authenticated);
        }

        fn onAuthWrite(
            bus_: ?*Bus,
            _: *xev.Loop,
            c: *xev.Completion,
            _: Unix,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            _ = r catch |err| {
                log.err("client auth write err: {any}", .{err});
                bus.err = err;
                return .disarm;
            };

            assert(bus.state == .authenticating or bus.state == .authenticated);
            if (bus.state == .authenticated) return .disarm;

            bus.read(c, onAuthRead);

            return .disarm;
        }

        fn onAuthRead(
            bus_: ?*Bus,
            l: *xev.Loop,
            c: *xev.Completion,
            socket: Unix,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            const n = r catch |err| {
                log.err("client auth read err: {any}", .{err});
                bus.err = err;
                return .disarm;
            };

            const slice = b.slice[0..n];

            if (bus.state != .authenticating) {
                log.err("client auth read unexpected state: {any}", .{bus.state});
                socket.shutdown(l, c, Bus, bus, onShutdown);
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
                    socket.shutdown(l, c, Bus, bus, onShutdown);
                    return .disarm;
                }
            };

            if (!ok) {
                log.err("client auth rejected: {s}", .{slice});
                socket.shutdown(l, c, Bus, bus, onShutdown);
                return .disarm;
            }

            bus.server_address = iter.next() orelse unreachable;
            bus.state = .authenticated;
            bus.write("BEGIN\r\n", onAuthWrite);
            return .disarm;
        }

        pub fn hello(bus: *Bus) !void {
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
            while (true) {
                if (bus.err) |e| return e;
                switch (bus.state) {
                    .ready => break,
                    .authenticated => try bus.loop.run(.once),
                    else => return error.Unexpected,
                }
            }
        }

        fn onHelloWrite(
            bus_: ?*Bus,
            _: *xev.Loop,
            c: *xev.Completion,
            _: Unix,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            _ = r catch |err| {
                log.err("client hello write err: {any}", .{err});
                bus.err = err;
                return .disarm;
            };

            bus.read(c, onHelloRead);
            return .disarm;
        }

        fn onHelloRead(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            var bus = bus_.?;
            const n = r catch |err| {
                log.err("client hello read err: {any}", .{err});
                bus.err = err;
                return .disarm;
            };

            var fbs = std.io.fixedBufferStream(b.slice[0..n]);
            const reader = fbs.reader();
            while (true) {
                var msg = Message.decode(bus.allocator, reader) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => {
                        log.err("client hello read err: {any}", .{e});
                        return .disarm;
                    },
                };
                defer msg.deinit(bus.allocator);

                if (msg.header.msg_type == .signal) {
                    if (std.mem.eql(u8, "NameAcquired", msg.member.?)) {
                        bus.name_acquired_signal_received = true;
                    }
                }

                if (msg.header.msg_type == .method_return) {
                    bus.name = bus.allocator.dupe(
                        u8, msg.values.?.values.getLast().inner.string.inner
                    ) catch unreachable;
                }
            }

            if (!bus.name_acquired_signal_received or bus.name == null)
                return .rearm;

            bus.state = .ready;
            return .disarm;
        }

        fn requestBoundNames(
            bus: *Bus,
        ) !void {
            if (bus.interfaces.count() == 0) return;
            var iter = bus.interfaces.keyIterator();
            while (iter.next()) |name| {
                try bus.requestName(name.*);
            }
        }

        pub fn requestName(bus: *Bus, name: []const u8) !void {
            log.info("requesting name: {s}", .{name});
            var msg = message.RequestName;
            msg.header.flags = 0x02; // replace existing
            defer msg.deinit(bus.allocator);
            try msg.appendString(bus.allocator, .string, name);
            try msg.appendNumber(bus.allocator, @as(u32, 1));

            try bus.writeMsg(&msg);
            bus.read(null, struct {
                fn cb(
                    bus_: ?*Bus,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Unix,
                    b: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const n = r catch |err| {
                        log.err("client hello read err: {any}", .{err});
                        return .disarm;
                    };

                    var fbs = std.io.fixedBufferStream(b.slice[0..n]);
                    while (true) {
                        var msg_ = Message.decode(bus_.?.allocator, fbs.reader()) catch |err| switch (err) {
                            error.EndOfStream => break,
                            else => {
                                log.err("client request name read err: {any}", .{err});
                                return .disarm;
                            },
                        };
                        defer msg_.deinit(bus_.?.allocator);

                        if (msg_.header.msg_type == .signal) continue;
                        switch (msg_.values.?.get(0).?.inner.uint32) {
                            1 => {
                                log.debug("client request name read: name acquired\n", .{});
                                return .disarm;
                            },
                            2, => {
                                log.debug("client request name read: name already exists, added to queue\n", .{});
                                return .disarm;
                            },
                            3, => {
                                log.debug("client request name read: name already exists, cannot aquire\n", .{});
                                return .disarm;
                            },
                            4, => {
                                log.debug("client request name read: client is already owner of name\n", .{});
                                return .disarm;
                            },
                            // There are only 4 possible values
                            // but zig requires handling all cases
                            else => {
                                log.err("client request name read: unexpected reply value: {d}", .{msg_.values.?.get(0).?.inner.uint32});
                                return .disarm;
                            }
                        }
                    }
                    return .rearm;
                }
            }.cb);
            try bus.run(.until_done);
            assert(bus.state == .ready);
        }

        pub fn writeMsg(bus: *Bus, msg: *Message) !void {
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
            bus: *Bus,
            c: ?*xev.Completion,
            cb: ?fn(
                ?*Bus,
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
                Bus,
                bus,
                cb orelse onRead,
            );
        }

        fn onRead(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            if (bus.state != .ready) return .disarm;
            assert(bus.state == .ready);
            assert(bus.socket != null);

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
            bus: *Bus,
            b: []const u8,
            cb: ?fn(
                ?*Bus,
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
                Bus,
                bus,
                cb orelse onWrite,
            );
        }

        fn onWrite(
            bus_: ?*Bus,
            l: *xev.Loop,
            c: *xev.Completion,
            socket: Unix,
            b: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            if (bus.state != .ready) return .disarm;
            assert(bus.state == .ready);
            assert(bus.socket != null);

            _ = r catch |err| {
                log.err("client write err: {any}", .{err});
                socket.shutdown(l, c, Bus, bus, onShutdown);
                return .disarm;
            };

            if (bus.write_callback) |cb| cb(bus);

            const buf = @as(*align(8) [MAX_BUFFER_SIZE]u8, @alignCast(@ptrCast(@constCast(b.slice))));
            bus.write_buffer_pool.destroy(buf);

            const req = xev.WriteRequest.from(c);
            bus.write_request_pool.destroy(req);

            return .disarm;
        }

        pub fn shutdown(bus: *Bus) void {
            if (bus.state == .shutdown) return;
            assert(bus.socket != null);
            assert(@intFromEnum(bus.state) > comptime @intFromEnum(State.connected));
            bus.state = .shutdown;
            const c = bus.completion_pool.create() catch unreachable;
            bus.socket.?.shutdown(
                &bus.loop,
                c,
                Bus,
                bus,
                onShutdown,
            );
        }

        fn onShutdown(
            bus_: ?*Bus,
            l: *xev.Loop,
            c: *xev.Completion,
            s: Unix,
            r: xev.ShutdownError!void,
        ) xev.CallbackAction {
            const bus = bus_.?;
            if (bus.state == .shutdown) return .disarm;

            _ = r catch |err| log.err("dbus shutdown err: {any}", .{err});

            log.debug("dbus shutdown: {any}", .{r});
            s.close(l, c, Bus, bus, onClose);
            return .disarm;
        }

        fn onClose(
            bus_: ?*Bus,
            _: *xev.Loop,
            c: *xev.Completion,
            _: Unix,
            r: xev.CloseError!void,
        ) xev.CallbackAction {
            const bus = bus_.?;
            if (bus.state == .shutdown) return .disarm;
            _ = r catch |err| log.err("client close err: {any}", .{err});

            log.debug("client close: {any}", .{r});
            bus_.?.completion_pool.destroy(c);
            bus_.?.state = .disconnected;
            bus_.?.socket = null;
            return .disarm;
        }
    };
}

test "setup and shutdown" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    var thread_pool = xev.ThreadPool.init(.{});
    var server = try Dbus(.server).init(allocator, &thread_pool, "/tmp/dbuz/dbus-test");
    defer server.deinit();

    try server.connect();
    try std.testing.expect(server.state == .connected);

    try server.authenticate();
    try std.testing.expect(server.state == .authenticated);

    try server.hello();
    try std.testing.expect(server.state == .ready);

    server.shutdown();
    try server.run(.until_done);
    try std.testing.expect(server.state == .shutdown);
}

test "failed auth disconnect" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    var thread_pool = xev.ThreadPool.init(.{});
    var server = try Dbus(.server).init(allocator, &thread_pool, "/tmp/dbuz/dbus-test");
    const Bus = @TypeOf(server);
    defer server.deinit();

    try server.connect();
    try std.testing.expect(server.state == .connected);

    // set our state to attemp auth but
    // send garbage so dbus disconnects us
    server.state = .authenticating;
    const msg = "garbage";

    server.write(msg, struct {
        fn cb(
            _: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            _: xev.WriteBuffer,
            _: xev.WriteError!usize,
        ) xev.CallbackAction { return .disarm; }
    }.cb);
    try server.run(.once);

    // our read should err after dbus disconnects us
    var c: xev.Completion = undefined;
    server.read(&c, struct {
        fn cb(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            _: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            _ = r catch |err| {
                bus_.?.err = err;
            };

            return .disarm;
        }
    }.cb);
    try server.run(.once);

    try std.testing.expect(server.err.? == error.ConnectionResetByPeer);
}

test "send msg" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    var server_thread_pool = xev.ThreadPool.init(.{});
    var server = try Dbus(.server).init(alloc, &server_thread_pool, "/tmp/dbuz/dbus-test");
    // var server = try Dbus.init(alloc, .server, &server_thread_pool, null);
    const ServerBus = @TypeOf(server);
    defer server.deinit();

    try server.startServerWithName("net.dbuz.test.SendMsg");
    try std.testing.expect(server.state == .ready);

    server.read_callback = struct {
        fn cb(bus: *ServerBus, m: *Message) void {
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

    var client_thread_pool = xev.ThreadPool.init(.{});
    var client = try Dbus(.client).init(alloc, &client_thread_pool, "/tmp/dbuz/dbus-test");
    // var client = try Dbus.init(alloc, .client, &client_thread_pool, null);
    const ClientBus = @TypeOf(client);
    defer client.deinit();
    try client.startClient();
    client.read(null, null);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
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
    try std.testing.expect(server.state == .shutdown);

    client.shutdown();
    client.run(.until_done) catch unreachable;
    try std.testing.expect(client.state == .shutdown);
}
