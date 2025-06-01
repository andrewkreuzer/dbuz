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

const xev = @import("xev");

const message = @import("message.zig");
const Dbus = @import("dbus.zig").Dbus;
const Message = message.Message;
const TypeSignature = @import("types.zig").TypeSignature;
const Values = @import("types.zig").Values;

pub const Interface = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,
    const VTable = struct {
        call: *const fn(*const anyopaque, *Dbus, *const Message) void,
    };

    pub fn call(
        b: *const Interface,
        bus: *Dbus,
        msg: *const Message,
    ) void {
        return b.vtable.call(b.ptr, bus, msg);
    }
};

pub fn BusInterface(comptime T: anytype) type {
    return struct {
        const Self = @This();

        i: *T,
        comptime methods: StaticStringMap(Method) = methodInfo(),

        const Fn = *const fn(*T, *Dbus, *const Message, ?[]const u8) void;
        const Method = struct{
            name: []const u8,
            member: []const u8,
            @"fn": Fn,
            return_sig: ?[]const u8 = null,
        };

        pub fn init(t: *T) Self {
            return .{.i = t};
        }

        pub fn interface(self: *const Self) Interface {
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
            bus: *Dbus,
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
                    const ret_info = @typeInfo(R);
                    _ = switch (ret_info) {
                        .void => @as(error{}!void, {}),
                        .bool => msg.appendBool(allocator, ret),
                        .int => |i| switch (i.bits) {
                            0...8 => msg.appendNumber(allocator, @as(u8, ret)),
                            9...16 => msg.appendNumber(
                                allocator,
                                if (i.signedness == .signed) @as(i16, ret)
                                else @as(u16, ret)
                            ),
                            17...32 => msg.appendNumber(
                                allocator,
                                if (i.signedness == .signed) @as(i32, ret)
                                else @as(u32, ret)
                            ),
                            33...64 => msg.appendNumber(
                                allocator,
                                if (i.signedness == .signed) @as(i64, ret)
                                else @as(u64, ret)
                            ),
                            else => @panic("invalid int, ints must be smaller than or equal to 64 bits")
                        },
                        .@"struct" => msg.appendStruct(allocator, ret),
                        .error_union => |e| blk: {
                            const r = ret catch |err| {
                                break :blk appendReturnValue(e.error_set, err, allocator, msg);
                            };
                            break :blk appendReturnValue(e.payload, r, allocator, msg);
                        },
                        .error_set => |eset| blk: {
                            if (eset) |_| {
                                msg.header.msg_type = .@"error";
                                msg.error_name = @errorName(ret);
                                msg.signature = "s";
                                break :blk msg.appendString(allocator, .string, @errorName(ret));
                            } else @panic("error_set must be set");
                        },
                        else => @panic("unsupported return type " ++ @typeName(R))

                    } catch @panic("failed to append return value to message");
                }

                fn f(t: *T, bus: *Dbus, msg: *const Message, sig: ?[]const u8) void {
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
    var server = try Dbus.init(alloc, null);
    defer server.deinit();

    const Test = struct {
        fn funciton(_: *@This()) void {}
    };

    var t: Test = .{};
    server.bind("net.dbuz.Test", BusInterface(Test).init(&t).interface());

    try server.startServer();
    try std.testing.expect(server.state == .ready);
    try std.testing.expect(server.interfaces.count() == 1);
    try std.testing.expect(server.interfaces.get("net.dbuz.Test") != null);

    server.read_callback = struct {
        fn cb(bus: *Dbus, m: *Message) void {
            if (m.reply_serial == null) return;
            if (m.reply_serial != 123) return;
            const name_has_owner = m.values.?
                .get(0)
                .?.inner
                .boolean;

            std.testing.expect(name_has_owner) catch unreachable;
            bus.shutdown();
        }
    }.cb;

    var msg = Message.init(.{
        .msg_type = .method_call,
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .destination = "org.freedesktop.DBus",
        .member = "NameHasOwner",
        .flags = 0x04,
        .serial = 123,
        .signature = "s",
    });
    try msg.appendString(alloc, .string, "net.dbuz.Test");
    defer msg.deinit(alloc);

    try server.writeMsg(&msg);
    try server.run(.until_done);
}

test "call" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;

    const Test = struct {
        a: u32 = 0,
        pub fn set(t: *@This()) void {
            t.a = 42;
        }
    };
    var t: Test = .{};

    var server = try Dbus.init(alloc, null);
    defer server.deinit();

    server.bind("net.dbuz.test.Call", BusInterface(Test).init(&t).interface());
    try server.startServer();
    try std.testing.expect(server.state == .ready);

    var client = Dbus.init(alloc, null) catch unreachable;
    defer client.deinit();

    client.startClient() catch unreachable;
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
    client.writeMsg(&msg) catch unreachable;
    msg.deinit(client.allocator);

    client.run(.once) catch unreachable;
    server.run(.once) catch unreachable;

    server.shutdown();
    server.run(.until_done) catch unreachable;
    try std.testing.expect(server.state == .disconnected);

    client.shutdown();
    client.run(.until_done) catch unreachable;
    try std.testing.expect(client.state == .disconnected);

    try std.testing.expectEqual(42, t.a);
}

test "return types" {
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;

    const Test = struct {
        a: u32 = 0,
        pub fn uint32(_: *@This()) u32 {
            return 42;
        }
        // pub fn string(_: *@This()) []const u8 {
        //     return "Hello, world!";
        // }
        pub fn boolean(_: *@This()) bool {
            return true;
        }
        pub fn structure(_: *@This()) extern struct { a: u32, b: u8 } {
            return .{ .a = 1, .b = 2 };
        }
        pub fn err(_: *@This()) error{Invalid} {
            return error.Invalid;
        }
    };
    var t: Test = .{};

    var server = try Dbus.init(alloc, null);
    defer server.deinit();

    server.bind("net.dbuz.test.ReturnTypes", BusInterface(Test).init(&t).interface());
    try server.startServer();
    try std.testing.expect(server.state == .ready);

    var client = Dbus.init(alloc, null) catch unreachable;
    defer client.deinit();

    client.startClient() catch unreachable;
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

    client.read(null, struct {
        fn cb(
            bus_: ?*Dbus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            const n = r catch |err| switch (err) {
                error.EOF => return .disarm,
                else => {
                    std.testing.expect(false) catch unreachable;
                    return .disarm;
                }
            };
            var fbs = std.io.fixedBufferStream(b.slice[0..n]);
            var msg = Message.decode(bus.allocator, fbs.reader()) catch {
                std.testing.expect(false) catch unreachable;
                return .disarm;
            };
            defer msg.deinit(bus.allocator);
            std.testing.expectEqual(
                42,
                msg.values.?.get(0).?.inner.uint32,
            ) catch unreachable;
            return .disarm;
        }
    }.cb);
    try client.run(.once);
    uint32.deinit(client.allocator);

    // var string = Message.init(.{
    //     .msg_type = .method_call,
    //     .path = "/net/dbuz/test/ReturnTypes",
    //     .interface = "net.dbuz.test.ReturnTypes",
    //     .destination = "net.dbuz.test.ReturnTypes",
    //     .member = "String",
    //     .flags = 0x04,
    // });
    // client.writeMsg(&string) catch unreachable;
    // string.deinit(client.allocator);

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

    client.read(null, struct {
        fn cb(
            bus_: ?*Dbus,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            b: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const bus = bus_.?;
            const n = r catch |err| switch (err) {
                error.EOF => return .disarm,
                else => {
                    std.testing.expect(false) catch unreachable;
                    return .disarm;
                }
            };
            var fbs = std.io.fixedBufferStream(b.slice[0..n]);
            var msg = Message.decode(bus.allocator, fbs.reader()) catch {
                std.testing.expect(false) catch unreachable;
                return .disarm;
            };
            defer msg.deinit(bus.allocator);
            std.testing.expect(
                msg.values.?.get(0).?.inner.boolean
            ) catch unreachable;
            return .disarm;
        }
    }.cb);
    try client.run(.once);
    boolean.deinit(client.allocator);

    // var structure = Message.init(.{
    //     .msg_type = .method_call,
    //     .path = "/net/dbuz/test/ReturnTypes",
    //     .interface = "net.dbuz.test.ReturnTypes",
    //     .destination = "net.dbuz.test.ReturnTypes",
    //     .member = "Structure",
    //     .flags = 0x04,
    // });
    // client.writeMsg(&structure) catch unreachable;
    // // STRUCTURE_SERIAL => {
    // //     std.debug.print("structure: {any}\n", .{
    // //         msg.values.?.get(0).?.inner.@"struct"
    // //     });
    // //     std.testing.expectEqual(
    // //         1,
    // //         msg.values.?
    // //         .get(0).?.inner.@"struct"
    // //         .get(0).?.inner.uint32
    // //     ) catch unreachable;
    // //     std.testing.expectEqual(
    // //         2,
    // //         msg.values.?
    // //         .get(0).?.inner.@"struct"
    // //         .get(1).?.inner.uint32
    // //     ) catch unreachable;
    // // },
    // structure.deinit(client.allocator);

    // var err = Message.init(.{
    //     .msg_type = .method_call,
    //     .path = "/net/dbuz/test/ReturnTypes",
    //     .interface = "net.dbuz.test.ReturnTypes",
    //     .destination = "net.dbuz.test.ReturnTypes",
    //     .member = "String",
    //     .flags = 0x04,
    // });
    // client.writeMsg(&err) catch unreachable;
    // // ERROR_SERIAL => {
    // //     std.testing.expectEqualStrings(
    // //         @errorName(error.Invalid),
    // //         msg.error_name.?
    // //     ) catch unreachable;
    // // },
    // err.deinit(client.allocator);

    server.shutdown();
    server.run(.until_done) catch unreachable;
    try std.testing.expect(server.state == .disconnected);

    client.shutdown();
    client.run(.until_done) catch unreachable;
    try std.testing.expect(client.state == .disconnected);

}
