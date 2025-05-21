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
                    const ret: ReturnType = @call(.auto, F, .{ t } ++ args.*);

                    if (msg.values) |values| {
                        assert(values.values.items.len == args.len);
                    }

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


const Test = extern struct {
    a: u32 = 22568,
    b: bool = true,
    // @"struct": TestStruct = TestStruct{ .a = 0x05, .b = 0x03 },
    array: [1]u8 = [_]u8{ 0x01 },

    pub fn sum_digits(self: *Test, b: u32) u32 {
        return self.a + b;
    }

    pub fn notify(self: *Test, b: u32) u32 {
        self.a += b;
        return self.a;
    }

    pub fn str(_: *Test, t: *TestStruct) []const u8 {
        return &t.c;
    }

    pub fn arr(_: *Test, a: []u8) []u8 {
        return a;
    }

    pub fn testStruct(_: *Test, test_struct: *TestStruct) TestStruct {
        test_struct.a = 0;
        return .{ .a = 0, .b = 0, .c = "What".* };
    }
};

const TestStruct = struct {
    a: u32,
    b: u32,
    c: [4:0]u8 = "Test".*,
};

// TOOD: Moving bus and msg into f breaks all these tests
// and arguably this should be more independent
// test "bind" {
//     const ArenaAllocator = std.heap.ArenaAllocator;
//     var bus = Dbus.init(std.testing.allocator);
//     var t = Test{};
//     const i: BusInterface = Interface(Test).init(&t).interface();
//     const allocator = std.testing.allocator;
//     var arena: ArenaAllocator = ArenaAllocator.init(allocator);
//     const alloc = arena.allocator();

//     // const stdin = std.io.getStdIn().reader();
//     // var buf: [128]u8 = undefined;
//     // const in = stdin.readUntilDelimiter(&buf, '\n') catch unreachable;

//     // {
//     //     const ret = try w.call(alloc, "Arr", .{in});
//     //     const r: [*:0]u8 = @ptrCast(@alignCast(ret.?));
//     //     std.debug.print("Arr: {s}\n", .{r});
//     //     alloc.free(r[0..in.len]);
//     // }

//     // our args must have a known type and can't
//     // when they're defined at comptime, otherwise
//     // we get an invalid pointer when cast to anyopaque
//     const args: struct {u32} = .{2};
//     for (0..5) |_| {
//         const ret = i.call(alloc, "Notify", &args);
//         std.debug.print("Notify: {d}\n", .{ret.cast(u32).?.*});
//     }

//     {
//         const ret = i.call(alloc, "SumDigits", &args);
//         std.debug.print("SumDigits: {d}\n", .{ret.cast(u32).?.*});
//     }

//     {
//         const ret = i.call(alloc, "SumDigits", &args);
//         std.debug.print("SumDigits: {d}\n", .{ret.cast(u32).?.*});
//     }

//     {
//         const test_struct = TestStruct{ .a = 1, .b = 2 };
//         // There's gotta be a way to inform anyopaque to populate
//         // correctly with the type, without having to explicity
//         // define it like this
//         const test_struct_arg: struct { *const TestStruct } = .{ &test_struct };
//         const ret = i.call(alloc, "Str", &test_struct_arg);
//         const s: [*:0]u8 = @alignCast(@ptrCast(@constCast(ret.ptr.?)));
//         std.debug.print("Str: {s}\n", .{s[0..4]});
//     }

//     {
//         var test_struct = TestStruct{ .a = 1, .b = 2 };
//         // There's gotta be a way to inform anyopaque to populate
//         // correctly with the type, without having to explicity
//         // define it like this
//         const test_struct_arg: struct { *TestStruct } = .{ &test_struct };
//         const ret = i.call(alloc, "TestStruct", &test_struct_arg);
//         std.debug.print("TestStruct: {s}\n", .{ret.cast(TestStruct).?.c});
//     }

//     const t1 = try std.time.Instant.now();
//     _ = arena.reset(.free_all);
//     const t2 = try std.time.Instant.now();

//     const elapsed = @as(f64, @floatFromInt(t2.since(t1)));
//     std.debug.print("{d:.2} ms\n", .{elapsed / std.time.ns_per_ms});

//     // var some_args = makeArgs();
//     // const a = w.call("Arr", .{&some_args});
//     // std.debug.print("Arr: {d}\n", .{a});

//     // var test_struct = TestStruct{ .a = 1, .b = 2 };
//     // const st = w.call("TestStruct", .{&test_struct});
//     // std.debug.print("Struct: {any}\n", .{test_struct});
//     // std.debug.print("Struct: {any}\n", .{st});
// }
