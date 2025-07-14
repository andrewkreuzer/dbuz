const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const log = std.log;
const mem = std.mem;
const meta = std.meta;
const toUpper = std.ascii.toUpper;
const Allocator = std.mem.Allocator;
const StaticStringMap = std.StaticStringMap;
const Tuple = meta.Tuple;
const Type = builtin.Type;

const message = @import("message.zig");
const Dbus = @import("dbus.zig").Dbus;
const Message = message.Message;
const TypeSignature = @import("types.zig").TypeSignature;
const Values = @import("types.zig").Values;

pub fn Interface(comptime BusType: type) type {
    return struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        const VTable = struct {
            call: *const fn(*const anyopaque, *BusType, *const Message) void,
        };

        pub fn call(
            b: *const Interface(BusType),
            bus: *BusType,
            msg: *const Message,
        ) void {
            return b.vtable.call(b.ptr, bus, msg);
        }
    };
}

pub fn BusInterface(comptime BusType: type, comptime T: anytype, bus_name: []const u8) type {
    return struct {
        const Self = @This();

        i: *T,
        comptime methods: StaticStringMap(Method) = methodInfo(),

        const Fn = *const fn(*T, *BusType, *const Message, ?[]const u8) void;
        const Method = struct{
            name: []const u8,
            member: []const u8,
            @"fn": Fn,
            return_sig: ?[]const u8 = null,
        };

        pub fn init(i: *T) Self {
            return .{.i = i};
        }

        pub fn interface(self: *const Self) Interface(BusType) {
            return .{
                .ptr = @ptrCast(@alignCast(self)),
                .vtable = &.{
                    .call = call,
                },
            };
        }

        fn method(l: *const Self, name: []const u8) ?Method {
            const m = l.methods.get(name);
            return m;
        }

        pub fn call(
            _i: *const anyopaque,
            bus: *BusType,
            msg: *const Message,
        ) void {
            const i: *const Self = @ptrCast(@alignCast(_i));
            const m = i.method(msg.member.?) orelse return;
            return m.@"fn"(i.i, bus, msg, m.return_sig);
        }

        fn count(name: []const u8) usize {
            var i: usize = 0;
            for (name) |c| {
                if (c != '_') i += 1;
            }
            return i;
        }

        fn convertName(name: [:0]const u8) *const [count(name):0]u8 {
            comptime {
                var out: [count(name):0]u8 = undefined;

                var i: usize = 0;
                var j: usize = 0;
                while (i < out.len) {
                    if (i == 0) {
                        out[i] = toUpper(name[j]);
                    } else if (name[j] == '_') {
                        j += 1;
                        out[i] = toUpper(name[j]);
                    } else {
                        out[i] = name[j];
                    }

                    i += 1;
                    j += 1;
                }

                const final = out;
                return &final;
            }
        }

        fn methodInfo() StaticStringMap(Method) {
            comptime {
                const declinfo = @typeInfo(T).@"struct".decls;
                const KV = struct { []const u8, Method };
                var kvs: [declinfo.len]KV = undefined;

                var i: usize = 0;
                for (declinfo) |decl| {
                    const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
                    if (decl_info != .@"fn") continue;

                    const dbus_name = convertName(decl.name);
                    const m: Method = .{
                        .name = decl.name,
                        .member = dbus_name,
                        .@"fn" = fnGeneric(Fn, decl.name, @field(T, decl.name)),
                        .return_sig = TypeSignature.signatureFromType(decl_info.@"fn".return_type.?),
                    };

                    kvs[i] = .{ dbus_name, m };
                    i += 1;

                }
                const mthds = StaticStringMap(Method).initComptime(kvs);
                return mthds;
            }
        }

        fn ParamTuple(params: []const Type.Fn.Param) type {
            comptime {
                var param_list: [params.len - 1]type = undefined;
                for (params[1..], 0..) |param, i| {
                    if (param.type == null) @compileError("invalid parameter type");
                    const param_info = @typeInfo(param.type.?);
                    _ = param_info;
                    param_list[i] = param.type.?;
                }
                return Tuple(&param_list);
            }
        }

        fn fnGeneric(
            comptime G: type,
            comptime name: []const u8,
            comptime F: anytype,
        ) G {
            return struct {
                const FnType = @TypeOf(F);
                const fn_info = @typeInfo(FnType);
                const fn_params = fn_info.@"fn".params;
                const Args: type = ParamTuple(fn_params);
                const args_type_info = @typeInfo(Args);
                const args_fields_info = args_type_info.@"struct".fields;
                const ReturnType = fn_info.@"fn".return_type.?;
                const return_info = @typeInfo(ReturnType);

                fn validate() void {
                    if (fn_info != .@"fn") {
                        @compileError("invalid function type");
                    }

                    if (fn_params.len == 0 or fn_params[0].type != *T) {
                        @compileError(
                            "invalid function, " ++ name ++ "(...)"
                            ++ " must be method of " ++ @typeName(*T)
                        );
                    }

                    if (args_type_info != .@"struct") {
                        @compileError("expected tuple or struct argument, found " ++ @typeName(Args));
                    }

                    if (args_fields_info.len + 1 != fn_params.len) {
                        @compileError("missmatch number of arguments, expected " ++
                            std.fmt.comptimePrint("{d}", .{fn_params.len}) ++
                            ", found " ++ std.fmt.comptimePrint("{d}", .{args_fields_info.len + 1}));
                    }
                }

                fn appendReturnValue(R: type, ret: R, allocator: Allocator, msg: *Message) !void {
                    try switch (@typeInfo(R)) {
                        .void => @as(error{}!void, {}),
                        .bool,
                        .int,
                        .float,
                        .pointer,
                        .array,
                        .@"struct"
                            => msg.appendAnyType(allocator, ret),
                        .error_union => |e| blk: {
                            const r = ret catch |err| {
                                break :blk appendReturnValue(e.error_set, err, allocator, msg);
                            };
                            break :blk appendReturnValue(e.payload, r, allocator, msg);
                        },
                        .error_set => |eset| blk: {
                            if (eset) |_| {
                                break :blk msg.appendError(allocator, bus_name, ret, null);
                            // We catch here although I don't know how you could define a null error_set
                            } else @compileError("interface return error_set must not be null");
                        },
                        else => @compileError("unsupported interface return type " ++ @typeName(R))

                    };
                }

                fn f(t: *T, bus: *BusType, msg: *const Message, sig: ?[]const u8) void {
                    comptime validate();
                    const args: *Args = @alignCast(@ptrCast(@constCast(msg.body_buf)));
                    if (msg.values) |values| {
                        assert(values.values.items.len == args.len);
                    }

                    const ret: ReturnType = @call(.auto, F, .{ t } ++ args.*);

                    var return_msg = Message.init(.{
                        .msg_type = .method_return,
                        .destination = msg.sender,
                        .sender = msg.destination,
                        .reply_serial = msg.header.serial,
                        .flags = 0x01,
                        .signature = sig,
                    });
                    defer return_msg.deinit(bus.allocator);
                    appendReturnValue(ReturnType, ret, bus.allocator, &return_msg) catch {
                        log.err("failed to append return value", .{});
                    };

                    bus.writeMsg(&return_msg) catch log.err("failed to write message", .{});
                }
            }.f;
        }
    };
}

test "bind" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const xev = @import("xev");

    var thread_pool = xev.ThreadPool.init(.{});
    // var server = try Dbus(.server).init(alloc, &thread_pool, "/tmp/dbus-test");
    var server = try Dbus(.server).init(alloc, &thread_pool, null);
    const ServerBus = @TypeOf(server);
    defer server.deinit();

    const Test = struct {
        fn funciton(_: *@This()) void {}
    };

    var t: Test = .{};
    const bus_name = "net.dbuz.test";
    try server.bind(bus_name ++ ".Test", BusInterface(ServerBus, Test, bus_name).init(&t).interface());
    try server.start(.{});

    try std.testing.expect(server.state == .ready);
    try std.testing.expectEqual(1, server.interfaces.count());
    try std.testing.expect(server.interfaces.get("net.dbuz.test.Test") != null);
    try std.testing.expectEqual(2, server.loop.active); // read, and shutdown are active

    server.read_callback = struct {
        fn cb(_: *ServerBus, m: *Message) void {
            const name_has_owner = m.values.?
                .get(0)
                .?.inner
                .boolean;

            std.testing.expect(name_has_owner) catch unreachable;
        }
    }.cb;

    var msg = message.NameHasOwner;
    try msg.appendString(alloc, .string, "net.dbuz.test.Test");
    defer msg.deinit(alloc);

    try server.writeMsg(&msg);
    try server.run(.once);

    // read and shutdown are still active
    try std.testing.expectEqual(2, server.loop.active);

    // read the reply
    try server.run(.once);

    try server.shutdown();
    try server.run(.until_done);
    try std.testing.expectEqual(.disconnected, server.state);
}

test "call" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const xev = @import("xev");

    const Test = struct {
        a: u32 = 0,
        pub fn set(t: *@This()) void {
            t.a = 42;
        }
    };
    var t: Test = .{};

    var server_thread_pool = xev.ThreadPool.init(.{});
    // var server = try Dbus(.server).init(alloc, &server_thread_pool, "/tmp/dbus-test");
    var server = try Dbus(.server).init(alloc, &server_thread_pool, null);
    const ServerBus = @TypeOf(server);
    defer server.deinit();

    const bus_name = "net.dbuz.test";
    try server.bind(bus_name ++ ".Call", BusInterface(ServerBus, Test, bus_name).init(&t).interface());
    try server.start(.{});
    try std.testing.expect(server.state == .ready);

    var client_thread_pool = xev.ThreadPool.init(.{});
    // var client = try Dbus(.client).init(alloc, &client_thread_pool, "/tmp/dbus-test");
    var client = try Dbus(.client).init(alloc, &client_thread_pool, null);
    defer client.deinit();

    try client.start(.{});
    try std.testing.expect(client.state == .ready);

    var msg = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/Call",
        .interface = "net.dbuz.test.Call",
        .destination = "net.dbuz.test.Call",
        .member = "Set",
        .flags = 0x04,
        .serial = 123,
    });
    try client.writeMsg(&msg);
    msg.deinit(client.allocator);
    try client.run(.once);

    try server.run(.once);
    try server.run(.once);

    try server.shutdown();
    try server.run(.until_done);
    try std.testing.expect(server.state == .disconnected);

    try client.shutdown();
    try client.run(.until_done);
    try std.testing.expect(client.state == .disconnected);

    try std.testing.expectEqual(42, t.a);
}

test "return types" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const xev = @import("xev");

    const Test = struct {
        a: u32 = 0,
        pub fn uint32(_: *@This()) u32 {
            return 42;
        }
        pub fn string(_: *@This()) []const u8 {
            return "Hello, World!";
        }
        pub fn boolean(_: *@This()) bool {
            return true;
        }
        pub fn structure(_: *@This()) extern struct { a: u32, b: u8 } {
            return .{ .a = 1, .b = 2 };
        }
        pub fn err(_: *@This()) error{Invalid} {
            return error.Invalid;
        }
        pub fn maybe_err(_: *@This(), b: bool) error{Invalid}!u8 {
            if (b) return 42;
            return error.Invalid;
        }
    };
    var t: Test = .{};

    var server_thread_pool = xev.ThreadPool.init(.{});
    // var server = try Dbus(.server).init(alloc, &server_thread_pool, "/tmp/dbus-test");
    var server = try Dbus(.server).init(alloc, &server_thread_pool, null);
    const ServerBus = @TypeOf(server);
    defer server.deinit();

    const bus_name = "net.dbuz.test";
    try server.bind(bus_name ++ ".ReturnTypes", BusInterface(ServerBus, Test, bus_name).init(&t).interface());
    try server.start(.{});
    try std.testing.expect(server.state == .ready);

    var client_thread_pool = xev.ThreadPool.init(.{});
    // var client = try Dbus(.client).init(alloc, &client_thread_pool, "/tmp/dbus-test");
    var client = try Dbus(.client).init(alloc, &client_thread_pool, null);
    const ClientBus = @TypeOf(client);
    defer client.deinit();

    try client.start(.{.start_read = true});
    try std.testing.expect(client.state == .ready);

    var uint32 = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/ReturnTypes",
        .interface = "net.dbuz.test.ReturnTypes",
        .destination = "net.dbuz.test.ReturnTypes",
        .member = "Uint32",
        .flags = 0x04,
    });
    try client.writeMsg(&uint32);
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expectEqual(
                42,
                m.values.?.get(0).?.inner.uint32,
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);
    uint32.deinit(client.allocator);

    var string = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/ReturnTypes",
        .interface = "net.dbuz.test.ReturnTypes",
        .destination = "net.dbuz.test.ReturnTypes",
        .member = "String",
        .flags = 0x04,
    });
    client.writeMsg(&string) catch unreachable;
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expectEqualStrings(
                "Hello, World!",
                m.values.?.get(0).?.inner.string.inner
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);
    string.deinit(client.allocator);

    var boolean = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/ReturnTypes",
        .interface = "net.dbuz.test.ReturnTypes",
        .destination = "net.dbuz.test.ReturnTypes",
        .member = "Boolean",
        .flags = 0x04,
    });
    try client.writeMsg(&boolean);
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expect(
                m.values.?.get(0).?.inner.boolean
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);
    boolean.deinit(client.allocator);

    var structure = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/ReturnTypes",
        .interface = "net.dbuz.test.ReturnTypes",
        .destination = "net.dbuz.test.ReturnTypes",
        .member = "Structure",
        .flags = 0x04,
    });
    client.writeMsg(&structure) catch unreachable;
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expectEqual(
                1,
                m.values.?
                .get(0).?.inner.@"struct"
                .get(0).?.inner.uint32
            ) catch unreachable;
            std.testing.expectEqual(
                2,
                m.values.?
                .get(0).?.inner.@"struct"
                .get(1).?.inner.byte
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);
    structure.deinit(client.allocator);

    var err_msg = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/ReturnTypes",
        .interface = "net.dbuz.test.ReturnTypes",
        .destination = "net.dbuz.test.ReturnTypes",
        .member = "Err",
        .flags = 0x04,
    });
    client.writeMsg(&err_msg) catch unreachable;
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expectEqualStrings(
                "net.dbuz.test.Error." ++ @errorName(error.Invalid),
                m.error_name.?
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);
    err_msg.deinit(client.allocator);

    var maybe_err_msg = Message.init(.{
        .msg_type = .method_call,
        .path = "/net/dbuz/test/ReturnTypes",
        .interface = "net.dbuz.test.ReturnTypes",
        .destination = "net.dbuz.test.ReturnTypes",
        .member = "MaybeErr",
        .signature = "b",
        .flags = 0x04,
    });
    maybe_err_msg.appendBool(alloc, false) catch unreachable;
    client.writeMsg(&maybe_err_msg) catch unreachable;
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expect(m.error_name != null) catch unreachable;
            std.testing.expectEqualStrings(
                "net.dbuz.test.Error." ++ @errorName(error.Invalid),
                m.error_name.?
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);

    alloc.free(maybe_err_msg.body_buf.?);
    alloc.free(maybe_err_msg.fields_buf.?);
    maybe_err_msg.values.?.values.items[0].inner.boolean = true;

    client.writeMsg(&maybe_err_msg) catch unreachable;
    try client.run(.once);

    // read and write
    try server.run(.once);
    try server.run(.once);

    client.read_callback = struct {
        fn cb(_: *ClientBus, m: *Message) void {
            std.testing.expect(m.error_name == null) catch unreachable;
            std.testing.expectEqual(
                42,
                m.values.?.get(0).?.inner.byte
            ) catch unreachable;
        }
    }.cb;
    try client.run(.once);
    maybe_err_msg.deinit(client.allocator);

    try server.shutdown();
    try server.run(.until_done);
    try std.testing.expect(server.state == .disconnected);

    try client.shutdown();
    try client.run(.until_done);
    try std.testing.expect(client.state == .disconnected);

}
