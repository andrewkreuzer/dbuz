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

const message = @import("message.zig");
const iface = @import("interface.zig");
const Interface = iface.BusInterface;
const ReturnPtr = iface.ReturnPtr;
const Message = message.Message;
const Hello = message.Hello;
const Value = message.Value;

pub const Dbus = struct {
    loop: xev.Loop,
    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,

    socket: ?Unix = null,
    path: []const u8,

    allocator: Allocator,
    read_buf: [1024]u8 = undefined,
    write_buf: [1024]u8 = undefined,
    message_pool: MemoryPool(Message) = undefined,

    state: State,

    uid: u32 = 0,
    name: ?[]const u8 = null,
    server_address: ?[]const u8 = undefined,

    interfaces: StringHashMap(Interface) = undefined,
    read_callback: ?*const fn (bus: *Dbus, msg: Message) void = null,
    write_callback: ?*const fn (bus: *Dbus) void = null,

    const State = enum {
        disconnected,
        connecting,
        connected,
        authenticating,
        authenticated,
        ready,
    };

    pub fn init(allocator: Allocator) !Dbus {
        const uid = std.os.linux.getuid();
        return .{
            .loop = try xev.Loop.init(.{}),
            .path = defaultSocketPath(uid),
            .state = .disconnected,
            .allocator = allocator,
            .message_pool = MemoryPool(Message).init(allocator),
            .uid = uid,
            .interfaces = StringHashMap(Interface).init(allocator),
        };
    }

    pub fn deinit(bus: *Dbus) void {
        if (bus.name) |name| bus.allocator.free(name);
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

    pub fn start(bus: *Dbus) !void {
        try bus.connect();
        try bus.authenticate();
        try bus.hello();
        try bus.requestBoundNames();
        bus.read(null, null);
    }

    pub fn run(bus: *Dbus, mode: xev.RunMode) !void {
        try bus.loop.run(mode);
    }

    pub fn connect(bus: *Dbus) !void {
        const addr = try std.net.Address.initUnix(bus.path);
        bus.socket = try Unix.init(addr);

        assert(bus.socket != null);
        assert(bus.socket.?.fd != -1);
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
        var c: xev.Completion = undefined;
        const msg = "\x00AUTH EXTERNAL 31303030\r\n";
        bus.write(msg, &c, onAuthWrite);
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
            log.err("client write err: {any}", .{err});
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
            log.err("client read err: {any}", .{err});
            return .disarm;
        };

        const slice = b.slice[0..n];

        if (bus.state != .authenticating) {
            log.err("client read unexpected state: {any}", .{bus.state});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        }

        var iter = std.mem.splitScalar(u8, slice, ' ');
        const ok = iter.first();
        if (!std.mem.eql(u8, ok, "OK")) {
            log.err("client read unexpected: {s}", .{slice});
            socket.shutdown(l, c, Dbus, bus, onShutdown);
            return .disarm;
        }

        bus.server_address = iter.next() orelse unreachable;

        bus.state = .authenticated;
        bus.write("BEGIN\r\n", c, onAuthWrite);
        return .disarm;
    }

    pub fn hello(bus: *Dbus) !void {
        assert(bus.state == .authenticated);
        var msg = Hello;
        var fbs = std.io.fixedBufferStream(&bus.write_buf);
        const writer = fbs.writer();

        try msg.encode(bus.allocator, writer);
        defer msg.deinit(bus.allocator);
        const bytes = fbs.getWritten();

        var c: xev.Completion = undefined;
        bus.write(bytes, &c, onHelloWrite);
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
            log.err("client write err: {any}", .{err});
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
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        var bus = bus_.?;
        _ = r catch |err| {
            log.err("client read err: {any}", .{err});
            return .disarm;
        };

        var fbs = std.io.fixedBufferStream(&bus.read_buf);
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
        try msg.appendString(bus.allocator, .string, name);
        try msg.appendInt(bus.allocator, .uint32, 1);

        var c: xev.Completion = undefined;
        try bus.writeMsg(&msg, &c);
        try bus.loop.run(.once);
    }

    pub fn writeMsg(bus: *Dbus, msg: *Message, c: ?*xev.Completion) !void {
        var fbs = std.io.fixedBufferStream(&bus.write_buf);
        const writer = fbs.writer();

        try msg.encode(bus.allocator, writer);
        defer msg.deinit(bus.allocator);

        const bytes = fbs.getWritten();
        bus.write(bytes, c, null);
    }

    fn read(
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

        bus.socket.?.read(
            &bus.loop,
            c orelse &bus.read_completion,
            .{ .slice = &bus.read_buf },
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
            error.EOF => return .rearm, // TODO
            else => {
                log.err("client read err: {any}", .{err});
                return .disarm;
            }
        };

        var fbs = std.io.fixedBufferStream(b.slice[0..n]);
        while (true) {
            var msg = Message.decode(bus.allocator, fbs.reader()) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    log.err("client read err: {any}", .{err});
                    return .disarm; // TODO: rearm
                },
            };
            defer msg.deinit(bus.allocator);

            if (bus.read_callback) |cb| cb(bus, msg);

            if (msg.interface == null) continue;
            if (msg.member == null) continue;

            const interface = bus.interfaces.get(msg.interface.?);
            if (interface) |i| i.call(bus, &msg);
        }

        return .rearm;
    }

    fn write(
        bus: *Dbus,
        b: []const u8,
        c: ?*xev.Completion,
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

        bus.socket.?.write(
            &bus.loop,
            c orelse &bus.write_completion,
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
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const bus = bus_.?;
        _ = r catch |err| switch (err) {
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.Canceled,
            error.Unexpected,
                => {
                log.err("client write err: {any}", .{err});
                socket.shutdown(l, c, Dbus, bus, onShutdown);
                return .disarm;
            }
        };
        if (bus.write_callback) |cb| cb(bus);

        return .disarm;
    }

    pub fn shutdown(bus: *Dbus) void {
        assert(bus.socket != null);
        assert(@intFromEnum(bus.state)
            > comptime @intFromEnum(State.connected)
        );
        bus.socket.?.shutdown(
            &bus.loop,
            &bus.read_completion,
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
        socket.close(l, c, Dbus, bus, onClose);
        return .disarm;
    }

    fn onClose(
        bus_: ?*Dbus,
        l: *xev.Loop,
        _: *xev.Completion,
        socket: Unix,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        _ = l;
        _ = socket;
        _ = r catch unreachable;
        log.debug("client close: {any}", .{r});

        bus_.?.state = .disconnected;
        return .disarm;
    }
};

