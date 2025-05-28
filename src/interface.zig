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

const Dbus = @import("dbus.zig").Dbus;
const Message = @import("message.zig").Message;
const TypeSignature = @import("types.zig").TypeSignature;
const Values = @import("types.zig").Values;

pub const BusInterface = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,
    const VTable = struct {
        call: *const fn(*const anyopaque, *Dbus, *const Message) void,
    };

    pub fn call(
        b: *const BusInterface,
        bus: *Dbus,
        msg: *const Message,
    ) void {
        return b.vtable.call(b.ptr, bus, msg);
    }
};

pub fn Interface(comptime T: anytype) type {
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

        pub fn interface(self: *const Self) BusInterface {
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
                        else => @panic("unsupported return type")

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
    server.bind("net.dbuz.Test", Interface(Test).init(&t).interface());

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
    const eql = std.mem.eql;
    const build_options = @import("build_options");
    if (!build_options.run_integration_tests) {
        return error.SkipZigTest;
    }

    var loop = try xev.Loop.init(.{});

    // notify accross threads the server is ready
    var notifier = try xev.Async.init();
    defer notifier.deinit();

    const Test = struct {
        a: u32 = 0,
        pub fn set(t: *@This()) void {
            t.a = 42;
        }
    };
    var t: Test = .{};

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn f(t_: *Test, n: *xev.Async) !void {
            const server_alloc = std.testing.allocator;
            var server = try Dbus.init(server_alloc, null);
            defer server.deinit();

            server.bind("net.dbuz.Test", Interface(Test).init(t_).interface());
            try server.startServer();

            server.read_callback = struct {
                fn cb(bus: *Dbus, m: *Message) void {
                    if (m.member == null) return;
                    if (eql(u8, m.member.?, "Shutdown")) {
                        var shutdown_msg = Message.init(.{
                            .msg_type = .method_return,
                            .destination = m.sender,
                            .sender = m.destination,
                            .reply_serial = m.header.serial,
                            .flags = 0x01,
                        });
                        defer shutdown_msg.deinit(bus.allocator);
                        bus.writeMsg(&shutdown_msg) catch unreachable;
                        bus.shutdown();
                    }
                }
            }.cb;

            try n.notify();
            try server.run(.until_done);
        }
    }.f, .{&t, &notifier});

    var c: xev.Completion = undefined;
    notifier.wait(&loop, &c, void, null, struct {
        fn cb(
            _: ?*void,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.Async.WaitError!void
        ) xev.CallbackAction {
            const client_alloc = std.testing.allocator;
            var client = Dbus.init(client_alloc, null) catch unreachable;
            defer client.deinit();
            client.startClient() catch unreachable;

            var msg = Message.init(.{
                .msg_type = .method_call,
                .path = "/net/dbuz/Test",
                .interface = "net.dbuz.Test",
                .destination = "net.dbuz.Test",
                .member = "Set",
                .flags = 0x04,
                .serial = 123,
            });
            client.writeMsg(&msg) catch unreachable;
            msg.deinit(client.allocator);
            client.run(.until_done) catch unreachable;

            var shutdown_msg = Message.init(.{
                .msg_type = .method_call,
                .path = "/net/dbuz/Test",
                .interface = "net.dbuz.Test",
                .destination = "net.dbuz.Test",
                .member = "Shutdown",
                .flags = 0x00,
            });
            client.writeMsg(&shutdown_msg) catch unreachable;
            shutdown_msg.deinit(client.allocator);
            client.run(.until_done) catch unreachable;

            return .disarm;
        }
    }.cb);

    try loop.run(.until_done);
    server_thread.join();
    try std.testing.expectEqual(42, t.a);
}
