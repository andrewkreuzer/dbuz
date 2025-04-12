const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const toUpper = std.ascii.toUpper;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;


pub fn Wrap(comptime T: anytype) type {
    return struct {
        const Wrapper = @This();

        wrapped: *T,
        // TODO I would love a map without allocations
        comptime methods: ?[]const Method = methodInfo(),

        const Method = struct{
            name: []const u8,
            dbus_name: []const u8,
            args: ?[]const Arg = null,
            return_type: type,
        };

        const Arg = struct{ type: type };

        fn bind(t: *T) Wrapper {
            return .{.wrapped = t};
        }

        fn count(name: []const u8) usize {
            var i: usize = 0;
            for (name) |c| {
                if (c != '_') i += 1;
            }
            return i;
        }

        inline fn convertName(name: [:0]const u8) *const [count(name):0]u8 {
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

        fn methodInfo() []const Method {
            comptime {
                var methods: []const Method = &[_]Method{};
                for (@typeInfo(T).@"struct".decls) |decl| {
                    const d_info = @typeInfo(@TypeOf(@field(T, decl.name))).@"fn";
                    var m: Method = .{ 
                        .name = decl.name,
                        .dbus_name = convertName(decl.name),
                        .return_type = d_info.return_type.?,
                    };

                    const params = d_info.params;
                    if (params.len == 0 or params[0].type != *T) {
                        @compileError(
                            "invalid function, "
                            ++ @typeName(T) ++ "." ++ decl.name ++ "(...)"
                            ++ " must be a method and take "
                            ++ @typeName(*T)
                            ++ " as it's first argument "
                        );
                    }

                    for (params) |param| {
                        if (m.args == null) m.args = &[_]Arg{};
                        m.args = m.args.? ++ [_]Arg{
                            .{.type = param.type.?},
                        };
                    }

                    methods = methods ++ &[_]Method{ m };
                }
                return methods;
            }
        }

        fn method(
            comptime methods: []const Method,
            comptime method_name: []const u8
        ) *const Method {
            comptime {
                for (methods) |m| {
                    if (mem.eql(u8, m.dbus_name, method_name)) {
                        return &m;
                    }
                }
                @compileError(
                    method_name
                    ++ " method not found on type: "
                    ++ @typeName(T)
                );
            }
        }

        fn ReturnType(
            comptime methods: []const Method,
            comptime method_name: []const u8
        ) type {
            const m = method(methods, method_name);
            return m.return_type;
        }

        fn call(
            w: *const Wrapper,
            comptime dbus_name: []const u8,
            args: anytype,
        ) ReturnType(w.methods.?, dbus_name) {
            const m = method(w.methods.?, dbus_name);
            const r = w.call_(m.name, args);
            return @as(
                *const ReturnType(w.methods.?, dbus_name),
                @alignCast(@ptrCast(r))
            ).*;
        }

        fn call_(
            w: *const Wrapper,
            comptime method_name: []const u8,
            args: anytype,
        ) *const anyopaque {
            const result = @call(
                .always_inline,
                @field(T, method_name),
                .{ w.wrapped } ++ args,
            );
            return @ptrCast(&result);
        }
    };
}

const Test = struct {
    a: u32 = 0,

    pub fn notify(self: *Test, b: u32) void {
        self.a += b;
        std.debug.print("notify called with event: {d}\n", .{b});
        std.debug.print("a: {d}\n", .{self.a});
    }

    pub fn sum_digits(self: *Test, b: u32) u32 {
        return self.a + b;
    }

    pub fn str(_: *Test) []const u8 {
        return "Test";
    }

    pub fn arr(_: *Test, a: []u8) []u8 {
        a[1] = 0;
        return a;
    }

    pub fn testStruct(_: *Test, test_struct: *TestStruct) TestStruct {
        test_struct.a = 0;
        return .{ .a = 0, .b = 0 };
    }
};

const TestStruct = struct {
    a: u32,
    b: u32,
};

fn makeArgs() [3]u8 {
    return [_]u8{ 1, 2, 3 };
}

test "bind" {
    var t = Test{};
    const w = Wrap(Test).bind(&t);

    _ = w.call("Notify", .{1});
    _ = w.call("Notify", .{1});
    _ = w.call("Notify", .{1});
    _ = w.call("Notify", .{1});
    _ = w.call("Notify", .{1});
    const r = w.call("SumDigits", .{5});
    std.debug.print("SumDigits: {d}\n", .{r});

    const s = w.call("Str", .{});
    std.debug.print("Str: {s}\n", .{s});

    var some_args = makeArgs();
    const a = w.call("Arr", .{&some_args});
    std.debug.print("Arr: {d}\n", .{a});

    var test_struct = TestStruct{ .a = 1, .b = 2 };
    const st = w.call("TestStruct", .{&test_struct});
    std.debug.print("Struct: {any}\n", .{test_struct});
    std.debug.print("Struct: {any}\n", .{st});
}
