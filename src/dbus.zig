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

const iface = @import("interface.zig");
const message = @import("message.zig");
const Hello = message.Hello;
const Interface = iface.BusInterface;
const Message = message.Message;
const ReturnPtr = iface.ReturnPtr;
const Value = message.Value;

const BufferPool = MemoryPool([4096]u8);
const CompletionPool = MemoryPool(xev.Completion);
const WriteRequestPool = MemoryPool(xev.WriteRequest);

pub const Dbus = struct {
    uid: u32 = 0,
    name: ?[]const u8 = null,
    server_address: ?[]const u8 = undefined,

    loop: xev.Loop,
    thread_pool: xev.ThreadPool,
    completion_pool: CompletionPool,
    write_queue: xev.WriteQueue = .{},
    write_request_pool: WriteRequestPool,

    socket: ?Unix = null,
    path: []const u8,
    msg_serial: u32 = 1,

    allocator: Allocator,
    read_buffer_pool: BufferPool,
    write_buffer_pool: BufferPool,

    state: State,

    interfaces: StringHashMap(Interface) = undefined,
    read_callback: ?*const fn (bus: *Dbus, msg: *Message) void = null,
    write_callback: ?*const fn (bus: *Dbus) void = null,

    stats: ?Stats = null,
    stats_loop: ?xev.Loop = null,
    stats_timer: ?xev.Timer = null,
    stats_completion: ?xev.Completion = null,
    stats_completion_cancel: ?xev.Completion = null,

    const State = enum {
        disconnected,
        connecting,
        connected,
        authenticating,
        authenticated,
        ready,
    };

    const Stats = struct {
        read: u64 = 0,
        write: u64 = 0,
        errors: u64 = 0,

        fn clear(s: *Stats) void {
            s.read = 0;
            s.write = 0;
            s.errors = 0;
        }
    };

    pub fn init(allocator: Allocator, stats: bool) !Dbus {
        const uid = blk: {
            const u = std.os.linux.getuid();
            if (u == 0) {
                // we are root, so we need to drop
                // privileges to connect
                try std.posix.setuid(1000);
                break :blk 1000;
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
            .path = defaultSocketPath(uid),
            .allocator = allocator,
            .write_buffer_pool = BufferPool.init(allocator),
            .read_buffer_pool = BufferPool.init(allocator),
            .state = .disconnected,
            .interfaces = StringHashMap(Interface).init(allocator),
            .stats = if (stats) .{} else null,
            .stats_loop = if (stats) try xev.Loop.init(.{
                .thread_pool = &thread_pool,
            }) else null,
            .stats_timer = if (stats) try xev.Timer.init() else null,
            .stats_completion = if (stats) .{} else null,
            .stats_completion_cancel = if (stats) .{} else null,
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
        bus.read_buffer_pool.deinit();
        bus.completion_pool.deinit();
        if (bus.stats) |_| {
            bus.stats_loop.?.stop();
            bus.stats_loop.?.deinit();
        }
        log.info("dbuz has been shutdown", .{});
    }

    pub fn bind(bus: *Dbus, name: []const u8, interface: Interface) void {
        bus.interfaces.put(name, interface) catch unreachable;
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
        if (bus.stats) |_| bus.startStats();
    }

    fn startStats(bus: *Dbus) void {
        bus.stats_timer.?.run(&bus.loop, &bus.stats_completion.?, 500, Dbus, bus, onStats);
    }

    fn onStats(
        bus_: ?*Dbus,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        var bus = bus_.?;
        const read_ps = @as(f64, @floatFromInt(bus.stats.?.read)) / 10;
        const write_ps = @as(f64, @floatFromInt(bus.stats.?.write)) / 10;
        const errors_ps = @as(f64, @floatFromInt(bus.stats.?.errors)) / 10;
        bus.stats.?.clear();
        log.info("dbus stats: read: {d}, write: {d}, error: {d}", .{read_ps, write_ps, errors_ps});

        bus.stats_timer.?.reset(
            &bus.loop,
            &bus.stats_completion.?,
            &bus.stats_completion_cancel.?,
            10000,
            Dbus,
            bus,
            onStats
        );

        return .disarm;
    }


    pub fn run(bus: *Dbus, mode: xev.RunMode) !void {
        try bus.loop.run(mode);
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

        const msg = "\x00AUTH EXTERNAL 31303030\r\n";
        bus.write(msg, onAuthWrite);
        try bus.loop.run(.until_done);
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
        try bus.loop.run(.until_done);
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
        try bus.loop.run(.once);
    }

    pub fn writeMsg(bus: *Dbus, msg: *Message) !void {
        msg.header.serial = bus.msg_serial;
        bus.msg_serial += 1;

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

        const buf = bus.read_buffer_pool.create() catch unreachable;
        const c_ = c orelse bus.completion_pool.create() catch unreachable;
        bus.socket.?.read(
            &bus.loop,
            c_,
            .{ .slice = buf },
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

        const minMsgSize = @sizeOf(message.Header);
        if (n < minMsgSize) {
            log.err("client read: to few bytes {d}/{d} of minimum message size", .{n, minMsgSize});
            return .disarm;
        }

        var fbs = std.io.fixedBufferStream(b.slice[0..n]);
        while (true) {
            var msg = Message.decode(bus.allocator, fbs.reader()) catch |err| switch (err) {
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
            defer msg.deinit(bus.allocator);

            if (bus.read_callback) |cb| cb(bus, &msg);

            if (msg.interface == null) continue;
            if (msg.member == null) continue;

            const interface = bus.interfaces.get(msg.interface.?);
            if (interface) |i| i.call(bus, &msg);
            if (bus.stats) |_| bus.stats.?.read += 1;
        }

        const buf = @as(*align(8) [4096]u8, @alignCast(@ptrCast(@constCast(b.slice))));
        bus.read_buffer_pool.destroy(buf);

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
        _ = r catch |err| switch (err) {
            // error.BrokenPipe,
            // error.ConnectionResetByPeer,
            // error.Canceled,
            // error.Unexpected,
            else
                => {
                log.err("client write err: {any}", .{err});
                socket.shutdown(l, c, Dbus, bus, onShutdown);
                return .disarm;
            }
        };
        if (bus.write_callback) |cb| cb(bus);
        if (bus.stats) |_| bus.stats.?.write += 1;

        const buf = @as(*align(8) [4096]u8, @alignCast(@ptrCast(@constCast(b.slice))));
        bus.write_buffer_pool.destroy(buf);

        const req = xev.WriteRequest.from(c);
        bus.write_request_pool.destroy(req);

        return .disarm;
    }

    pub fn shutdown(bus: *Dbus) void {
        assert(bus.socket != null);
        assert(@intFromEnum(bus.state)
            > comptime @intFromEnum(State.connected)
        );
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
        _ = r catch unreachable;
        log.debug("client shutdown: {any}", .{r});

        const bus = bus_.?;
        bus.loop.stop();
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
        _ = r catch unreachable;
        log.debug("client close: {any}", .{r});

        bus_.?.completion_pool.destroy(c);
        bus_.?.state = .disconnected;
        return .disarm;
    }
};

