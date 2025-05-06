const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const meta = std.meta;
const activeTag = meta.activeTag;
const toUpper = std.ascii.toUpper;
const Allocator = std.mem.Allocator;
const StaticStringMap = std.StaticStringMap;
const Type = builtin.Type;
const Tuple = meta.Tuple;

const xev = @import("xev");

const Dbus = @import("dbus.zig").Dbus;
const Message = @import("message.zig").Message;

pub fn Dispatch(comptime T: anytype) type {
    return struct {
        const Wrapper = @This();

        wrapped: *T,
        comptime methods: StaticStringMap(Method) = methodInfo(),

        // const Fn = FnUnion();
        const Fn = *const fn(*T, *const anyopaque) ?*anyopaque;
        const Method = struct{
            name: []const u8,
            dbus_name: []const u8,
            @"fn": Fn,
        };

        pub fn bind(t: *T) Wrapper {
            return .{.wrapped = t};
        }

        pub fn register(w: *const Wrapper, bus: *Dbus) !void {
            bus.wrapped = w;
            try bus.requestName(w.wrapped.name);
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
                        .dbus_name = dbus_name,
                        .@"fn" = fnGeneric(Fn, decl.name, @field(T, decl.name)),
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

                fn check() void {
                    if (fn_info != .@"fn") {
                        @compileError("invalid function type");
                    }

                    if (fn_params.len == 0 or fn_params[0].type != *T) {
                        @compileError(
                            "invalid function, " ++ name ++ "(...)"
                            ++ " must be  method of " ++ @typeName(*T)
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

                fn f(t: *T, in_args: *const anyopaque) ?*anyopaque {
                    comptime check();
                    const ReturnType = fn_info.@"fn".return_type.?;
                    const args_tuple: *const Args = @ptrCast(@alignCast(in_args));
                    if (ReturnType == void) {
                        @call(.auto, F, .{ t } ++ args_tuple.*);
                        return null;
                    }
                    var ret: ReturnType = @call(.auto, F, .{ t } ++ args_tuple.*);
                    return @ptrCast(@constCast(&ret));
                }
            }.f;
        }

        fn method(w: *const Wrapper, name: []const u8) ?Method {
            const m = w.methods.get(name);
            return m;
        }

        pub fn call(
            w: *const Wrapper,
            comptime dbus_name: []const u8,
            args: anytype,
        ) !?*anyopaque {
            const f = w.method(dbus_name) orelse return error.FunctionNotFound;
            return @call(.auto, f.@"fn", .{ w.wrapped, &args });
        }

        // pub fn methodCallCallback(
        //     w: *const Wrapper,
        //     _: *Dbus,
        //     m: Message,
        // ) void {
        //     const f = w.method(m.member.?).?.@"fn";
        //     @call(.auto, f, .{ w.wrapped });
        // }

        // pub fn methodReturnCallback(
        //     w: *const Wrapper,
        //     bus: *Dbus,
        //     m: Message,
        // ) void {
        //     const mthd = method(w.methods.?, m.member.?).?;
        //     const r = @call(
        //         .always_inline,
        //         @field(T, mthd.name),
        //         .{ w.wrapped },
        //     );
        //     bus.send(m.sender, r);
        // }

        // fn signalCallback(
        //     w: *const Wrapper,
        //     bus: *Dbus,
        //     m: Message,
        // ) void {
        //     const mthd = method(w.methods.?, m.member.?).?;
        //     const r = @call(
        //         .always_inline,
        //         @field(T, mthd.name),
        //         .{ w.wrapped },
        //     );
        //     bus.send(m.sender, r);
        // }

        // fn FnUnion() type {
        //     comptime {
        //         const declinfo = @typeInfo(T).@"struct".decls;
        //         var enumDecls: [declinfo.len]std.builtin.Type.EnumField = undefined;
        //         var unionDecls: [declinfo.len]std.builtin.Type.UnionField = undefined;
        //         var decls = [_]std.builtin.Type.Declaration{};
        //         var i: usize = 0;
        //         for (declinfo) |decl| {
        //             const d_info = @typeInfo(@TypeOf(@field(T, decl.name)));
        //             if (d_info != .@"fn") continue;
        //             enumDecls[i] = .{ .name = decl.name ++ "", .value = i };
        //             unionDecls[i] = .{
        //                 .name = decl.name ++ "",
        //                 .type = *const @TypeOf(@field(T, decl.name)),
        //                 .alignment = @alignOf(@TypeOf(&@field(T, decl.name)))
        //             };
        //             i += 1;
        //         }
        //         return @Type(.{
        //             .@"union" = .{
        //                 .layout = .auto,
        //                 .tag_type = @Type(.{
        //                     .@"enum" = .{
        //                         .tag_type = std.math.IntFittingRange(
        //                             0, if (enumDecls[0..i].len == 0) 0 else enumDecls[0..i].len - 1
        //                         ),
        //                         .fields = enumDecls[0..i],
        //                         .decls = &decls,
        //                         .is_exhaustive = true,
        //                     },
        //                     }),
        //                 .fields = unionDecls[0..i],
        //                 .decls = &decls,
        //             },
        //             });
        //     }
        // }

    };
}

const Test = extern struct {
    a: u32 = 22568,
    b: bool = true,
    @"struct": TestStruct = TestStruct{ .a = 0x05, .b = 0x03 },
    array: [1]u8 = [_]u8{ 0x01 },

    pub fn sum_digits(self: *Test, b: u32) u32 {
        return self.a + b;
    }

    pub fn notify(self: *Test, b: u32) u32 {
        self.a += b;
        return self.a;
    }

    pub fn str(_: *Test) []const u8 {
        return "Test";
    }

    // pub fn arr(_: *Test, a: []u8) []u8 {
    //     a[1] = 0;
    //     return a;
    // }

    // pub fn testStruct(_: *Test, test_struct: *TestStruct) TestStruct {
    //     test_struct.a = 0;
    //     return .{ .a = 0, .b = 0 };
    // }
};

const TestStruct = packed struct {
    a: u32,
    b: u32,
};

test "bind" {
    var t = Test{};
    const w = Dispatch(Test).bind(&t);

    // our args must have a known type and can't
    // when they're defined at comptime, otherwise
    // we can an invalid pointer when cast to anyopaque
    const args: struct {u32} = .{2};
    _ = try w.call("Notify", args);
    _ = try w.call("Notify", args);
    _ = try w.call("Notify", args);


    _ = try w.call("SumDigits", args);
    const r = try w.call("SumDigits", args);
    const r_: *u32 = @ptrCast(@alignCast(r));
    std.debug.print("SumDigits: {d}\n", .{r_.*});

    const s: [*:0]u8 = @alignCast(@ptrCast(try w.call("Str", .{})));
    std.debug.print("Str: {s}\n", .{s[0..4]});

    // var some_args = makeArgs();
    // const a = w.call("Arr", .{&some_args});
    // std.debug.print("Arr: {d}\n", .{a});

    // var test_struct = TestStruct{ .a = 1, .b = 2 };
    // const st = w.call("TestStruct", .{&test_struct});
    // std.debug.print("Struct: {any}\n", .{test_struct});
    // std.debug.print("Struct: {any}\n", .{st});
}
