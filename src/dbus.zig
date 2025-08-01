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
const Queue = @import("queue.zig").Queue;

// TODO:
// maximum size of a dbus message is 128MiB
const MAX_BUFFER_SIZE = 128 * 1024;
const MAX_QUEUE_SIZE = 512;
const BufferPool = MemoryPool([MAX_BUFFER_SIZE]u8);
const CompletionPool = MemoryPool(xev.Completion);
const WriteRequestPool = MemoryPool(xev.WriteRequest);
const MessagePool = MemoryPool(Message);

pub const BusType = enum {
    client,
    server,
};

const BusOptions = struct {
    allocator: Allocator,
    thread_pool: ?*xev.ThreadPool = null,
    path: ?[]const u8 = null,
};

pub fn Dbus(comptime bus_type: BusType) type {
    return struct {
        type: BusType,

        // The UID of the user that started the bus
        uid: u32 = 0,

        // The socket path either passed by caller or defaulted to
        // the current user's session bus socket path
        path: []const u8,

        // The guid of the server, if any.
        // This is sent by dbus after a successful authentication
        server_id: ?[]const u8 = undefined,

        // The name of the bus
        // This is sent by dbus after a successful hello
        name: ?[]const u8 = null,

        // The socket used to communicate with the dbus server
        socket: ?Unix = null,

        // A counter for the message serial number
        // incremented after each message sent
        msg_serial: u32 = 1, // TODO: should this be per sender, not per bus?

        loop: xev.Loop,
        thread_pool: ?*xev.ThreadPool,
        completion_pool: CompletionPool,

        read_completion: xev.Completion = undefined,
        write_completion_pool: CompletionPool,

        shutdown_async: xev.Async,
        shutdown_completion: xev.Completion = undefined,

        allocator: Allocator,
        // TODO:
        // I've solved having to deal with a partial msg
        // in a full buffer by simple making a bigger buffer
        // so that never happens 🫤. Although this isn't
        // even the dbus max message size...
        // 2 to the 27th power or 134217728 (128 MiB)
        read_buffer: [MAX_BUFFER_SIZE]u8 = undefined,
        write_buffer_pool: BufferPool,

        message_queue: Queue(Message),
        message_pool: MessagePool,

        state: State,
        connection_attempts: u8 = 0,
        max_connection_attempts: u8 = 3,

        // A map of interfaces bound to the bus, these map to structures and
        // methods that the bus can call when it receives a matching message
        interfaces: StringHashMap(Interface(Bus)),

        // A map of method handles, these are functions that are called when a
        // message with a matching method name is received. Our methods are a
        // map on the key of the full interface and member string, this way we
        // can store different interfaces in the same map
        method_handles: StringHashMap(*const fn (bus: *Bus, msg: *Message) void),

        // Callbacks for read and write operations, can be set by the user to
        // handle operations on message send and receive
        read_callback: ?*const fn (bus: *Bus, msg: *Message) void = null,
        write_callback: ?*const fn (bus: *Bus) void = null,

        const Bus = @This();

        const State = enum {
            disconnected,
            connecting,
            connected,
            authenticating,
            authenticated,
            hello,
            ready,
        };

        pub fn init(options: BusOptions) !Bus {
            const uid = std.os.linux.getuid();
            return .{
                .type = bus_type,
                .uid = uid,
                .path = options.path orelse defaultSocketPath(uid),
                .loop = try xev.Loop.init(.{ .thread_pool = options.thread_pool }),
                .thread_pool = options.thread_pool,
                .completion_pool = CompletionPool.init(options.allocator),
                .shutdown_async = try xev.Async.init(),
                .allocator = options.allocator,
                .write_buffer_pool = BufferPool.init(options.allocator),
                .write_completion_pool = CompletionPool.init(options.allocator),
                .message_queue = Queue(Message).init(MAX_QUEUE_SIZE),
                .message_pool = MessagePool.init(options.allocator),
                .state = .disconnected,
                .interfaces = StringHashMap(Interface(Bus)).init(options.allocator),
                .method_handles = StringHashMap(*const fn (bus: *Bus, msg: *Message) void).init(options.allocator),
            };
        }

        pub fn deinit(bus: *Bus) void {
            if (bus.name) |name| bus.allocator.free(name);
            bus.loop.stop();
            bus.loop.deinit();
            bus.interfaces.deinit();
            bus.method_handles.deinit();
            bus.write_buffer_pool.deinit();
            bus.write_completion_pool.deinit();
            bus.completion_pool.deinit();
            bus.message_pool.deinit();
            if (bus.thread_pool) |pool| {
                pool.shutdown();
                pool.deinit();
            }
        }

        pub fn bind(bus: *Bus, iface: Interface(Bus)) !void {
            try bus.interfaces.put(iface.name, iface);
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

        /// Run the bus loop
        /// uses xev's run modes `.no_wait`, `.once`, `.until_done`
        pub fn run(bus: *Bus, mode: xev.RunMode) !void {
            try bus.loop.run(mode);
        }

        fn run_until(bus: *Bus, state: State) !void {
            while (bus.state != state) {
                if (bus.state == .disconnected) return error.ConnectionInterupt;
                try bus.loop.run(.once);
            }
        }

        /// Options for starting the bus connection
        ///
        /// - `opts.start_read` is enabled by default for servers but is provided as an option
        /// for clients to allow them to start reading messages immediately after the
        /// bus is ready. or to disable immediate reading for servers
        pub const StartOptions = struct {
            start_read: bool = if (bus_type == .server) true else false,
            shutdown_async: bool = true,
        };

        /// Starts the bus connection
        ///
        /// a connection to the bus will be established, authenticated, and ready for use.
        /// if your server has any bindings or method handles they will created once the
        /// bus has completed the hello handshake
        ///
        /// the loop is left in control of the caller and can be started using the `bus.run(mode)`
        /// method passing the desired xev run mode.
        pub fn start(bus: *Bus, opts: StartOptions) !void {
            bus_state: switch (State.disconnected) {
                .disconnected => {
                    if (bus.state != .disconnected) {
                        log.err("dbus start: bus is already in state {s}", .{@tagName(bus.state)});
                        return;
                    }

                    assert(bus.socket == null);
                    assert(bus.state == .disconnected);

                    bus.state = .connecting;
                    continue :bus_state .connecting;
                },
                .connecting => {
                    bus.connect() catch |e| switch (e) {
                        error.ConnectionInterupt => {
                            log.err("dbus start: failed to connect to socket: {s}", .{bus.path});
                            continue :bus_state try bus.attemptReconnect();
                        },
                        else => return e
                    };

                    continue :bus_state .connected;
                },
                .connected => {
                    assert(bus.socket != null);
                    assert(bus.state == .connected);

                    bus.state = .authenticating;
                    continue :bus_state .authenticating;
                },
                .authenticating => {
                    bus.authenticate() catch |e| switch (e) {
                        error.ConnectionInterupt => {
                            log.err("dbus start: failed to authenticate to socket: {s}", .{bus.path});
                            continue :bus_state try bus.attemptReconnect();
                        },
                        else => return e
                    };

                    continue :bus_state .authenticated;
                },
                .authenticated => {
                    assert(bus.socket != null);
                    assert(bus.state == .authenticated);
                    assert(bus.server_id != null);

                    bus.state = .hello;
                    continue :bus_state .hello;
                },
                .hello => {
                    bus.sendHello() catch |e| switch (e) {
                        error.ConnectionInterupt => {
                            log.err("dbus start: failed to send hello message: {s}", .{bus.path});
                            continue :bus_state try bus.attemptReconnect();
                        },
                        else => return e
                    };
                    continue :bus_state .ready;
                },
                .ready => {
                    assert(bus.socket != null);
                    assert(bus.state == .ready);
                    assert(bus.server_id != null);
                    assert(bus.name != null);

                    if (opts.shutdown_async) {
                        bus.shutdown_async.wait(
                            &bus.loop,
                            &bus.shutdown_completion,
                            Bus,
                            bus,
                            shutdownAsyncCallback
                        );
                    }

                    if (bus_type == .server) {
                        try bus.requestBoundNames();
                        try bus.requestMethodHandles();
                    }
                    if (opts.start_read) bus.read(null, null);
                },
            }
        }

        fn connect(bus: *Bus) !void {
            const addr = try std.net.Address.initUnix(bus.path);
            bus.socket = try Unix.init(addr);

            assert(bus.socket != null);
            assert(bus.state == .connecting);

            bus.connection_attempts += 1;
            var c: xev.Completion = undefined;
            bus.socket.?.connect(&bus.loop, &c, addr, Bus, bus, onConnect);
            try bus.run_until(.connected);
        }

        fn attemptReconnect(
            bus: *Bus,
        ) !State {
            if (bus.connection_attempts >= bus.max_connection_attempts) {
                log.err(
                    "dbus connect: max connection attempts reached ({d}/{d})",
                    .{bus.connection_attempts, bus.max_connection_attempts}
                );
                try bus.shutdown();
                try bus.run(.until_done);
                bus.deinit();
                std.posix.exit(1);
            }

            log.info(
                "dbus connect: retrying connection to {s} ({d}/{d})",
                .{bus.path, bus.connection_attempts, bus.max_connection_attempts}
            );
            bus.state = .connecting;
            return .connecting;
        }

        fn onConnect(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            r: xev.ConnectError!void,
        ) xev.CallbackAction {
            const bus = bus_.?;
            _ = r catch |e| {
                log.err("dbus connect err: {any}", .{e});
                bus.state = .disconnected;
                return .disarm;
            };

            assert(bus.socket != null);
            assert(bus.state == .connecting);
            bus.state = .connected;
            bus.connection_attempts = 0;
            return .disarm;
        }

        fn authenticate(bus: *Bus) !void {
            assert(bus.socket != null);
            assert(bus.state == .authenticating);

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
            try bus.run_until(.authenticated);
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
            _ = r catch |e| {
                log.err("dbus auth write err: {any}", .{e});
                bus.state = .disconnected;
                return .disarm;
            };

            assert(bus.state == .authenticating);

            bus.read(c, onAuthRead);
            return .disarm;
        }

        fn onAuthRead(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            const n = r catch |e| {
                log.err("dbus auth read err: {any}", .{e});
                bus.state = .disconnected;
                return .disarm;
            };

            const slice = b.slice[0..n];

            var iter = std.mem.splitScalar(u8, slice, ' ');
            const first = iter.first();
            if (std.mem.eql(u8, first, "REJECTED")) {
                log.err("dbus auth rejected: {s}", .{slice});
                bus.state = .disconnected;
                return .disarm;
            }

            log.debug("dbus auth succeeded: {s}", .{slice[0..n-1]});
            bus.server_id = iter.next() orelse {
                log.err("dbus auth read: no server address in response: {s}", .{slice});
                return .disarm;
            };

            bus.write("BEGIN\r\n", onBeginWrite);
            return .disarm;
        }

        fn onBeginWrite(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: Unix,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            _ = r catch |e| {
                log.err("dbus begin write err: {any}", .{e});
                bus.state = .disconnected;
                return .disarm;
            };
            bus.state = .authenticated;
            return .disarm;
        }

        fn sendHello(bus: *Bus) !void {
            assert(bus.socket != null);
            assert(bus.state == .hello);

            var msg = Hello;
            defer msg.deinit(bus.allocator);

            msg.header.serial = bus.msg_serial;
            bus.msg_serial += 1;

            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();
            try msg.encode(bus.allocator, writer);

            bus.write(fbs.getWritten(), onHelloWrite);
            try bus.run_until(.ready);
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
            _ = r catch |e| {
                log.err("dbus hello write err: {any}", .{e});
                bus.state = .disconnected;
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
            const n = r catch |e| {
                log.err("dbus hello read err: {any}", .{e});
                bus.state = .disconnected;
                return .disarm;
            };

            bus.readBufferMessages(b.slice[0..n]);
            var read_hello_response = false;
            while (bus.message_queue.pop()) |msg| {
                defer bus.message_pool.destroy(msg);
                defer msg.deinit(bus.allocator);

                if (msg.header.msg_type == .signal) continue;
                if (msg.header.msg_type == .method_return) {
                    // TODO: assumptions
                    read_hello_response = true;
                    bus.name = bus.allocator.dupe(
                        u8, msg.values.?.values.getLast().inner.string.inner
                    ) catch |e| {
                        log.err("dbus hello read allocation err: {any}", .{e});
                        return .disarm;
                    };
                }
            }

            if (!read_hello_response) return .rearm;
            bus.state = .ready;
            return .disarm;
        }

        pub fn setMethodHandle(
            bus: *Bus,
            comptime name: []const u8,
            cb: fn (bus: *Bus, msg: *Message) void,
        ) !void {
            bus.method_handles.put(name, cb) catch |e| {
                log.err("dbus set method handle err: {any}", .{e});
                return e;
            };
        }

        fn requestMethodHandles(
            bus: *Bus,
        ) !void {
            if (bus.method_handles.count() == 0) return;
            var iter = bus.method_handles.keyIterator();
            while (iter.next()) |name| {
                var split = std.mem.splitBackwardsScalar(u8, name.*, '.');
                const member = split.first();
                if (member.len == 0) {
                    log.err("dbus set method handle: no member name in {s}", .{name});
                    return error.InvalidArgument;
                }

                const iface = split.rest();
                if (iface.len == 0) {
                    log.err("dbus set method handle: no interface name in {s}", .{name});
                    return error.InvalidArgument;
                }

                try bus.requestName(iface);
            }
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

        fn requestName(bus: *Bus, name: []const u8) !void {
            log.info("requesting name: {s}", .{name});
            var req_msg = message.RequestName;
            defer req_msg.deinit(bus.allocator);
            try req_msg.appendString(bus.allocator, .string, name);
            try req_msg.appendNumber(bus.allocator, @as(u32, 1));

            try bus.writeMsg(&req_msg);
            bus.read(null, struct {
                fn cb(
                    bus_: ?*Bus,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Unix,
                    b: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const n = r catch |e| {
                        log.err("dbus hello read err: {any}", .{e});
                        return .disarm;
                    };

                    bus_.?.readBufferMessages(b.slice[0..n]);
                    while (bus_.?.message_queue.pop()) |msg| {
                        defer bus_.?.message_pool.destroy(msg);
                        defer msg.deinit(bus_.?.allocator);

                        if (msg.header.msg_type == .signal) continue;
                        switch (msg.values.?.get(0).?.inner.uint32) {
                            1 => {
                                log.debug("dbus request name read: name acquired", .{});
                                return .disarm;
                            },
                            2, => {
                                log.debug("dbus request name read: name already exists, added to queue", .{});
                                return .disarm;
                            },
                            3, => {
                                log.debug("dbus request name read: name already exists, cannot aquire", .{});
                                return .disarm;
                            },
                            4, => {
                                log.debug("dbus request name read: dbus is already owner of name", .{});
                                return .disarm;
                            },
                            // There are only 4 possible values
                            // but zig requires handling all cases
                            else => {}
                        }
                    }
                    return .rearm;
                }
            }.cb);
            try bus.run(.once); // write
            try bus.run(.once); // read
            try bus.run(.no_wait); // rearm
            assert(bus.state == .ready);
        }

        pub fn readMsg(
            bus: *Bus,
        ) !*Message {
            if (bus.message_queue.empty()) {
                bus.read(null, struct {
                    fn cb(
                        bus_: ?*Bus,
                        _: *xev.Loop,
                        _: *xev.Completion,
                        _: Unix,
                        b: xev.ReadBuffer,
                        r: xev.ReadError!usize,
                    ) xev.CallbackAction {
                        const n = r catch |e| {
                            log.err("dbus read msg err: {any}", .{e});
                            return .disarm;
                        };
                        bus_.?.readBufferMessages(b.slice[0..n]);
                        return .disarm;
                    }
                }.cb);
                try bus.run(.once);
            }

            const msg: *Message = bus.message_queue.pop()
                orelse return error.NoMessageAvailable;

            // TODO: ignore signals for now
            if (msg.header.msg_type == .signal) return error.NoMessageAvailable;

            return msg;
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

            if (@intFromEnum(bus.state) < @intFromEnum(State.connected)) {
                log.err("dbus read: bus is disconnected", .{});
                return;
            }
            assert(@intFromEnum(bus.state) > @intFromEnum(State.connected));

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

            const n = r catch |e| switch (e) {
                error.EOF => return .disarm,
                else => {
                    log.err("dbus read err: {any}", .{e});
                    return .disarm;
                }
            };

            if (n < Message.MinimumSize) {
                log.err(
                    "dbus read: to few bytes {d}/{d} of minimum message size",
                    .{n, Message.MinimumSize}
                );
                return .disarm;
            }

            bus.readBufferMessages(b.slice[0..n]);
            while (bus.message_queue.pop()) |msg| {
                defer bus.message_pool.destroy(msg);
                defer msg.deinit(bus.allocator);

                // fire our read_callback if we have one,
                // we do this before checking message fields
                // so it fires for all messages
                if (bus.read_callback) |cb| cb(bus, msg);

                // TODO: we ignore signals for now
                if (msg.header.msg_type == .signal) continue;

                // these fields are required in order to determine
                // which functions to fire and where, so we skip
                // the message if they're not found
                const iface = msg.interface orelse continue;
                const member = msg.member orelse continue;
                const method_parts = [_][]const u8{iface, ".", member};

                const method = std.mem.join(
                    bus.allocator,
                    "",
                    &method_parts
                ) catch |e| {
                    log.err("dbus read: failed to join iface and member: {any}", .{e});
                    continue;
                };
                defer bus.allocator.free(method);

                if (bus.method_handles.get(method)) |cb| cb(bus, msg);
                if (bus.interfaces.get(iface)) |i| i.call(bus, msg);
            }

            return .rearm;
        }

        fn readBufferMessages(bus: *Bus, buf: []const u8) void {
            var fbs = std.io.fixedBufferStream(buf);
            while (true) {
                const msg: *Message = bus.message_pool.create() catch |e| {
                    log.err("dbus read message pool: {any}", .{e});
                    return;
                };
                msg.* = Message.decode(bus.allocator, fbs.reader()) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => {
                        log.err("dbus read err: {any}", .{e});
                        return;
                    },
                };

                log.debug(
                    "dbus read msg: type: {s} serial: {d} reply_serial: {any} interface: {s} path: {s} member: {s}",
                    .{
                        @tagName(msg.header.msg_type),
                        msg.header.serial,
                        msg.reply_serial,
                        msg.interface orelse "null",
                        msg.path orelse "null",
                        msg.member orelse "null",
                    }
                );
                bus.message_queue.push(msg) catch |e| {
                    log.err("dbus read message queue: {any}", .{e});
                };
            }
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

            log.debug(
                "dbus writing msg: type: {s} serial: {d} reply_serial: {any} interface: {s} path: {s} member: {s} len: {d}",
                .{
                    @tagName(msg.header.msg_type),
                    msg.header.serial,
                    msg.reply_serial,
                    msg.interface orelse "null",
                    msg.path orelse "null",
                    msg.member orelse "null",
                    bytes.len
                }
            );
            bus.write(bytes, null);
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

            if (@intFromEnum(bus.state) < @intFromEnum(State.connected)) {
                log.err("dbus write: bus is disconnected", .{});
                return;
            }

            const c = bus.write_completion_pool.create() catch |e| {
                log.err("dbus write completion pool create err: {any}", .{e});
                return;
            };
            bus.socket.?.write(
                &bus.loop,
                c,
                .{ .slice = b },
                Bus,
                bus,
                cb orelse onWrite,
            );
        }

        fn onWrite(
            bus_: ?*Bus,
            _: *xev.Loop,
            c: *xev.Completion,
            _: Unix,
            b: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            _ = r catch |e| {
                log.err("dbus write err: {any}", .{e});
                return .disarm;
            };

            assert(bus.state == .ready);
            assert(bus.socket != null);

            if (bus.write_callback) |cb| cb(bus);

            const buf = @as(*align(8) [MAX_BUFFER_SIZE]u8, @alignCast(@ptrCast(@constCast(b.slice))));
            bus.write_buffer_pool.destroy(buf);
            bus.write_completion_pool.destroy(c);

            return .disarm;
        }

        pub fn shutdown(bus: *Bus) !void {
            log.debug("dbus shutting down", .{});
            try bus.shutdown_async.notify();
        }

        pub fn shutdownAsyncCallback(
            bus_: ?*Bus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const bus = bus_.?;
            if (bus.state == .disconnected) return .disarm;

            assert(bus.socket != null);
            assert(@intFromEnum(bus.state) > @intFromEnum(State.connected));

            const c = bus.completion_pool.create() catch |e| {
                log.err("dbus shutdown async completion pool create err: {any}", .{e});
                return .disarm;
            };
            bus.socket.?.shutdown(
                &bus.loop,
                c,
                Bus,
                bus,
                onShutdown,
            );

            return .disarm;
        }

        fn onShutdown(
            bus_: ?*Bus,
            l: *xev.Loop,
            c: *xev.Completion,
            s: Unix,
            r: xev.ShutdownError!void,
        ) xev.CallbackAction {
            const bus = bus_.?;
            if (bus.state == .disconnected) return .disarm;
            _ = r catch |e| {
                log.err("dbus shutdown err: {any}", .{e});
                return .disarm;
            };

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
            if (bus.state == .disconnected) return .disarm;
            _ = r catch |e| {
                log.err("dbus socket close err: {any}", .{e});
            };

            log.debug("dbus socket closed\n", .{});
            bus.completion_pool.destroy(c);
            bus.state = .disconnected;
            bus.socket = null;
            return .disarm;
        }
    };
}

test Dbus {
    // only included to avoid failed test runs on 
    // systems without dbus
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    var thread_pool = xev.ThreadPool.init(.{});
    var server = try Dbus(.server).init(.{
        .allocator = allocator,
        .thread_pool = &thread_pool
    });
    defer server.deinit();

    try server.setMethodHandle("net.dbuz.example.Echo", struct {
        fn cb(bus: *Dbus(.server), m: *Message) void {
            var echo = m.*;
            defer echo.deinit(bus.allocator);
            echo.header.msg_type = .method_return;
            echo.destination = m.sender;
            echo.sender = m.destination;
            echo.reply_serial = m.header.serial;
            echo.header.flags = 0x01;
            bus.writeMsg(&echo) catch unreachable;
        }
    }.cb);

    try server.start(.{});
    // you should use the appropriate run mode, we use no_wait
    // as we aren't sending any messages to this server so once,
    // or until_done would block
    try server.run(.no_wait);
    try server.shutdown();
}

test "setup and shutdown" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    var thread_pool = xev.ThreadPool.init(.{});
    // var server = try Dbus(.server).init(allocator, &thread_pool, "/tmp/dbus-test");
    var server = try Dbus(.server).init(.{
        .allocator = allocator,
        .thread_pool = &thread_pool
    });
    defer server.deinit();

    server.state = .connecting;
    try server.connect();
    try std.testing.expect(server.state == .connected);

    server.state = .authenticating;
    try server.authenticate();
    try std.testing.expect(server.state == .authenticated);

    server.state = .hello;
    try server.sendHello();
    try std.testing.expect(server.state == .ready);

    // TODO: not ideal
    server.shutdown_async.wait(
        &server.loop,
        &server.shutdown_completion,
        @TypeOf(server),
        &server,
        Dbus(.server).shutdownAsyncCallback
    );

    try server.shutdown();
    try server.run(.until_done);
    try std.testing.expect(server.state == .disconnected);
}

test "failed auth disconnect" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    var thread_pool = xev.ThreadPool.init(.{});
    // var server = try Dbus(.server).init(allocator, &thread_pool, "/tmp/dbus-test");
    var server = try Dbus(.server).init(.{
        .allocator = allocator,
        .thread_pool = &thread_pool
    });
    const Bus = @TypeOf(server);
    defer server.deinit();

    server.state = .connecting;
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
            _ = r catch {
                const bus = bus_.?;
                bus.state = .disconnected;
            };

            return .disarm;
        }
    }.cb);
    try server.run(.once);

    try std.testing.expect(server.state == .disconnected);
}

test "send msg" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    var server_thread_pool = xev.ThreadPool.init(.{});
    // var server = try Dbus(.server).init(alloc, &server_thread_pool, "/tmp/dbus-test");
    var server = try Dbus(.server).init(.{
        .allocator = alloc,
        .thread_pool = &server_thread_pool
    });
    const ServerBus = @TypeOf(server);
    defer server.deinit();

    try server.setMethodHandle("net.dbuz.test.SendMsg.Test", struct {
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
    }.cb);

    try server.start(.{});
    try std.testing.expect(server.state == .ready);

    var client_thread_pool = xev.ThreadPool.init(.{});
    // var client = try Dbus(.client).init(alloc, &client_thread_pool, "/tmp/dbus-test");
    var client = try Dbus(.client).init(.{
        .allocator = alloc,
        .thread_pool = &client_thread_pool
    });
    const ClientBus = @TypeOf(client);
    defer client.deinit();
    try client.start(.{});
    client.read(null, null);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            if (m.header.msg_type == .signal) return;
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

    try server.shutdown();
    server.run(.until_done) catch unreachable;
    try std.testing.expect(server.state == .disconnected);

    try client.shutdown();
    client.run(.until_done) catch unreachable;
    try std.testing.expect(client.state == .disconnected);
}

test "method_handle not found" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    var client_thread_pool = xev.ThreadPool.init(.{});
    // var client = try Dbus(.client).init(alloc, &client_thread_pool, "/tmp/dbus-test");
    var client = try Dbus(.client).init(.{
        .allocator = alloc,
        .thread_pool = &client_thread_pool
    });
    const ClientBus = @TypeOf(client);
    defer client.deinit();
    try client.start(.{ .start_read = true });

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            if (m.header.msg_type == .signal) return;
            std.testing.expectEqual(.@"error", m.header.msg_type) catch unreachable;
            std.testing.expectEqualStrings("org.freedesktop.DBus.Error.ServiceUnknown", m.error_name.?) catch unreachable;
            std.testing.expectEqual(2, m.reply_serial.?) catch unreachable;
        }
    }.cb;

    var msg = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/MethodNotFound",
        .interface = "net.dbuz.test.MethodNotFound",
        .destination = "net.dbuz.test.MethodNotFound",
        .member = "NotFound",
        .flags = 0x00,
    });
    try client.writeMsg(&msg);
    try client.run(.once);
    msg.deinit(client.allocator);

    // read
    try client.run(.once);

    try client.shutdown();
    client.run(.until_done) catch unreachable;
    try std.testing.expect(client.state == .disconnected);
}
