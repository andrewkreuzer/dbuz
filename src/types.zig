const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Endian = std.builtin.Endian;
const Writer = std.io.AnyWriter;

pub const TypeSignature = enum(u8) {
    null,
    byte = 'y',
    boolean = 'b',
    int16 = 'n',
    uint16 = 'q',
    int32 = 'i',
    uint32 = 'u',
    int64 = 'x',
    uint64 = 't',
    double = 'd',
    string = 's',
    object_path = 'o',
    signature = 'g',
    array = 'a',
    @"struct" = '(', // r
    variant = 'v',
    dict_entry = '{', // e
    unix_fd = 'h',

    pub inline fn fromType(T: type) @This() {
        comptime {
            const sig = @typeInfo(T);
            return switch (sig) {
                .void => .null,
                .null, .optional => @compileError("Invalid type, functions cannot return null"),
                .bool => .boolean,
                .int => |i| switch (i.bits) {
                    0...8 => .byte,
                    9...16 => if (i.signedness == .unsigned) .uint16 else .int16,
                    17...32 => if (i.signedness == .unsigned) .uint32 else .int32,
                    33...64 => if (i.signedness == .unsigned) .uint64 else .int64,
                    else => @compileError("Invalid int, dbus only supports up to 8, 16, 32, and 64 bit integers"),
                },
                .float => |f| blk: {
                    if (f.bits != 64) @compileError("Invalid float, dbus only supports IEEE 754 floats");
                    break :blk .double;
                },
                .array => .array,
                .@"struct" => .@"struct",
                else => .null,
            };
        }
    }

    pub inline fn signatureFromType(T: type) ?[]const u8 {
        comptime {
            const sig = @typeInfo(T);
            return switch (sig) {
                .void => null,
                .null, .optional => @compileError("Invalid type, functions cannot return null"),
                .bool => "b",
                .int => |i| switch (i.bits) {
                    0...8 => "y",
                    9...16 => if (i.signedness == .unsigned) "q" else "n",
                    17...32 => if (i.signedness == .unsigned) "u" else "i",
                    33...64 => if (i.signedness == .unsigned) "t" else "x",
                    else => @compileError("Invalid int, dbus only supports up to 8, 16, 32, and 64 bit integers"),
                },
                .float => |f| blk: {
                    if (f.bits != 64) @compileError("Invalid float, dbus only supports IEEE 754 floats");
                    break :blk "d";
                },
                .array => |a| "a" ++ signatureFromType(a.child).?,
                .@"struct" => |s| blk: {
                    var fields: []const u8 = "";
                    for (s.fields) |f| {
                        fields = fields ++ (signatureFromType(f.type) orelse ""); // TODO
                    }
                    break :blk "(" ++ fields ++ ")";
                },
                else => null,
            };
        }
    }

    /// get the Dbus spec alignment for the given type type
    fn alignOf(self: TypeSignature) usize {
        return switch (self) {
            .null, .signature, .variant, .byte => 1,
            .int16, .uint16 => 2,
            .int32, .uint32, .boolean, .string, .object_path, .array, .unix_fd => 4,
            .int64, .uint64, .double, .@"struct", .dict_entry => 8,
        };
    }

    /// get the offset to the next alignment for this type
    pub fn alignOffset(self: TypeSignature, index: usize) usize {
        if (index == 0) return 0;
        const alignment = self.alignOf();
        return (~index + 1) & (alignment - 1);
    }
};

pub const ValueUnion = union(TypeSignature) {
    null: void,
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    string: String,
    object_path: ObjectPath,
    signature: Signature,
    array: Values,
    @"struct": Values,
    variant: struct{[]const u8, *Value},
    dict_entry: Values,
    unix_fd: i32,

};

pub const String = struct {
    inner: []const u8,
};

pub const ObjectPath = struct {
    inner: []const u8,
};

pub const Signature = struct {
    inner: []const u8,
};

pub const Value = struct {
    type: TypeSignature,
    inner: ValueUnion,
    contained_sig: ?[]const u8 = null,
    slice: ?[]const u8 = null,
};

pub const Values = struct {
    values: ArrayList(Value),

    const Self = @This();

    pub fn init(alloc: Allocator) Values {
        return .{
            .values = ArrayList(Value).init(alloc),
        };
    }

    fn free(alloc: Allocator, value: *Value) void {
        switch (value.*.inner) {
            .array, .@"struct", .dict_entry => |*val| {
                val.deinit(alloc);
            },
            .variant => |v| {
                free(alloc, v[1]);
                alloc.destroy(v[1]);
            },
            else => {},
        }
    }

    pub fn deinit(self: *Values, alloc: Allocator) void {
        for (self.values.items) |*value| {
            free(alloc, value);
        }
        self.values.deinit();
    }

    pub fn len(self: *const Values) usize {
        return self.values.items.len;
    }

    /// Get a reference to the value at the given index,
    /// returns null if the index is out of bounds.
    pub fn get(self: *Values, index: usize) ?*Value {
        if (index >= self.values.items.len) return null;
        return &self.values.items[index];
    }

    /// Append a new value to the values array.
    pub fn append(self: *Values, value: Value) !void {
        try self.values.append(value);
    }

    pub fn appendAnyType(self: *Values, alloc: Allocator, value: anytype) !void {
        try switch(@typeInfo(@TypeOf(value))) {
            // .type => values.append(.{}),
            // .void => values.append(.{}),
            .bool => self.values.append(.{ .type = .boolean, .inner = .{ .boolean = value }}),
            // .noreturn => values.append(.{}),
            .int => |i| switch (i.bits) {
                0...8 => self.values.append(.{ .type = .byte, .inner = .{ .byte = @as(u8, value) }}),
                9...16 => self.values.append(.{
                    .type = if (i.signedness == .signed) .int16 else .uint16,
                    .inner =
                        if (i.signedness == .signed) .{ .int16 = @as(i16, value) }
                        else .{ .uint16 = @as(u16, value) }
                }),
                17...32 => self.values.append(.{
                    .type = if (i.signedness == .signed) .int32 else .uint32,
                    .inner =
                        if (i.signedness == .signed) .{ .int32 = @as(i32, value) }
                        else .{ .uint32 = @as(u32, value) }
                }),
                33...64 => self.values.append(.{
                    .type = if (i.signedness == .signed) .int64 else .uint64,
                    .inner =
                        if (i.signedness == .signed) .{ .int64 = @as(i64, value) }
                        else .{ .uint64 = @as(u64, value) }
                }),
                else => @panic("invalid int, ints must be smaller than or equal to 64 bits")
            },
            .float => |i| switch (i.bits) {
                64 => self.values.append(.{ .type = .double, .inner = .{ .double = @as(f64, value) }}),
                else => @panic("invalid float, floats must be equal to 64 bits (IEEE 574)")
            },
            .pointer => |p| switch (p.size) {
                .one => self.appendAnyType(value.*),
                .many => {},
                .slice => blk: {
                    // TODO: should we assume const u8 slices are strings?
                    if (p.child == u8 and p.is_const) {
                        break :blk self.append(.{
                            .type = .string,
                            .inner = .{ .string = String{ .inner = value } }
                        });
                    }
                    break :blk self.append(.{
                        .type = .array,
                        .inner = .{ .array = Values.fromSlice(alloc, p.child, value.*) }
                    });
                },
                .c => {},
            },
            .array => self.appendArray(alloc, value),
            .@"struct" => self.appendStruct(alloc, value),
            .comptime_float => self.values.append(.{}),
            .comptime_int => self.values.append(.{}),
            // .undefined => values.append(.{}),
            // .null => values.append(.{}),
            // .optional => values.append(.{}),
            // .error_union => values.append(.{}),
            // .error_set => values.append(.{}),
            // .@"enum" => values.append(.{}),
            // .@"union" => values.append(.{}),
            // .@"fn" => values.append(.{}),
            // .@"opaque" => values.append(.{}),
            // .frame => values.append(.{}),
            // .@"anyframe" => values.append(.{}),
            // .vector => values.append(.{}),
            // .enum_literal => values.append(.{}),
            else => return error.InvalidType,
        };
    }

    pub fn appendSliceOfValues(self: *Self, slice: []const Value) !void {
        try self.values.appendSlice(slice);
    }

    pub fn fromSliceOfValues(alloc: Allocator, slice: []const Value) !Values {
        var values = try ArrayList(Value).initCapacity(alloc, slice.len);
        try values.insertSlice(0, slice);
        return .{ .values = values };
    }

    pub fn fromSlice(alloc: Allocator, Child: anytype, slice: []const Child) !Values {
        var slice_values = Values.init(alloc);
        for (slice) |item| {
            try slice_values.appendAnyType(alloc, item);
        }

        var values = ArrayList(Value).init(alloc);
        try values.append(.{ .type = .array, .inner = .{ .array = slice_values }, .contained_sig = "" });
        return .{ .values = values };
    }

    pub fn fromArray(alloc: Allocator, Child: anytype, array: []const Child) !Values {
        var array_values = Values.init(alloc);
        for (array) |item| {
            try array_values.appendAnyType(alloc, item);
        }
        var values = ArrayList(Value).init(alloc);
        try values.append(.{
            .type = .array,
            .inner = .{ .array = array_values },
            .contained_sig = ""
        });
        return .{ .values = values };
    }

    pub fn appendArray(self: *Self, alloc: Allocator, array: anytype) !void {
        const array_info = @typeInfo(@TypeOf(array));
        assert(array_info == .array);
        const sig = TypeSignature.signatureFromType(@TypeOf(array));

        var array_values = Values.init(alloc);
        for (array) |item| {
            try array_values.appendAnyType(alloc, item);
        }
        try self.values.append(.{
            .type = .array,
            .inner = .{ .array = array_values },
            .contained_sig = sig,
        });
    }

    fn writeBytes(comptime T: type, w: Writer, pos: usize, v: T) !usize {
        var i = pos;
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                try w.writeByteNTimes(0x00, TypeSignature.@"struct".alignOffset(i));
                inline for (struct_info.fields) |f| {
                    if (struct_info.backing_integer) |Int| {
                        const bytes = std.mem.toBytes(@as(Int, @bitCast(@field(v, f.name))));
                        try w.writeAll(&bytes);
                        i += bytes.len;
                    } else {
                        i += try writeBytes(f.type, w, i, @field(v, f.name));
                    }
                }
            },
            .array => |a| {
                // @sizeOf(v) isn't going to work with structs
                try w.writeInt(u32, @as(u32, @sizeOf(@TypeOf(v))), builtin.target.cpu.arch.endian());
                try w.writeByteNTimes(0x00, TypeSignature.fromType(a.child).alignOffset(i));
                try w.writeAll(@as([]const u8, @ptrCast(&v)));
                // for (v) |item| {
                //     i += try writeBytes(@TypeOf(item), w, i, item);
                // }
            },
            .@"enum" => {
                const bytes = std.mem.toBytes(@intFromEnum(v));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .bool => {
                const bytes = std.mem.toBytes(@as(u32, @intFromBool(v)));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .float => |float_info| {
                const bytes = std.mem.toBytes(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(v)));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            else => {
                const bytes = std.mem.toBytes(v);
                try w.writeAll(&bytes);
                i += bytes.len;
            },
        }
        return i;
    }


    fn writeSwappedBytes(comptime T: type, w: Writer, pos: usize, v: T) !usize {
        var i = pos;
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                try w.writeByteNTimes(0x00, TypeSignature.@"struct".alignOffset(i));
                inline for (struct_info.fields) |f| {
                    if (struct_info.backing_integer) |Int| {
                        const bytes = std.mem.toBytes(@byteSwap(@as(Int, @bitCast(@field(v, f.name)))));
                        try w.writeAll(&bytes);
                        i += bytes.len;
                    } else {
                        i += try writeSwappedBytes(f.type, w, i, @field(v, f.name));
                    }
                }
            },
            .array => {
                try w.writeByteNTimes(0x00, TypeSignature.fromType(@TypeOf(v[0])).alignOffset(i));
                try w.writeInt(
                    u32,
                    @as(u32, v.len),
                    if (builtin.target.cpu.arch.endian() == .little) .big else .little,
                );
                for (v) |item| {
                    i += try writeSwappedBytes(@TypeOf(item), w, i, item);
                }
            },
            .@"enum" => {
                const bytes = std.mem.toBytes(@byteSwap(@intFromEnum(v)));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .bool => {
                const bytes = std.mem.toBytes(@byteSwap(@as(u32, @intFromBool(v))));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .float => |float_info| {
                const bytes = std.mem.toBytes(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(v))));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .pointer => |p| switch (p.size) {
                .one => i += try writeSwappedBytes(p.child, w, i, v.*),
                .slice => {}, // i += try writeBytes([v.len]u8, w, i, v.*),
                .c, .many => {},
            },
            else => {
                const bytes = std.mem.toBytes(@byteSwap(v));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
        }
        return i;
    }

    fn writeLittle(comptime T: type, w: Writer, pos: usize, v: T) !usize {
        return switch (builtin.target.cpu.arch.endian()) {
            .little => writeBytes(T, w, pos, v),
            .big => writeSwappedBytes(T, w, pos, v),
        };
    }

    fn writeBig(comptime T: type, w: Writer, pos: usize, v: T) !usize {
        return switch (builtin.target.cpu.arch.endian()) {
            .little => writeSwappedBytes(T, w, pos, v),
            .big => writeBytes(T, w, pos, v),
        };
    }

    fn writeBytesWithEndian(comptime T: type, w: Writer, pos: usize, v: T, endianness: Endian) !usize {
        return switch (endianness) {
            .little => writeLittle(T, w, pos, v),
            .big => writeBig(T, w, pos, v),
        };
    }

    pub fn appendStruct(self: *Self, alloc: Allocator, @"struct": anytype) !void {
        const struct_info = @typeInfo(@TypeOf(@"struct"));
        assert(struct_info == .@"struct");
        const sig = TypeSignature.signatureFromType(@TypeOf(@"struct"));

        var buf = ArrayList(u8).init(alloc);
        const buf_writer = buf.writer();

        var struct_values = Values.init(alloc);
        inline for (@typeInfo(@TypeOf(@"struct")).@"struct".fields) |f| {
            const value = @field(@"struct", f.name);
            try struct_values.appendAnyType(alloc, value);
            _ = try writeBytesWithEndian(@TypeOf(value), buf_writer.any(), buf.items.len, value, .little);
        }

        try self.append(.{
            .type = .@"struct",
            .inner = .{ .@"struct" = struct_values },
            .contained_sig = sig,
            .slice = try buf.toOwnedSlice()
        });
    }
};

test "values from struct" {
    const alloc = std.testing.allocator;
    const s = struct {
        a: u8,
        b: u16,
        c: u32,
        d: u64,
        e: f64,
        f: bool,
        g: []const u8,
    }{
        .a = 1,
        .b = 2,
        .c = 3,
        .d = 4,
        .e = 5.0,
        .f = true,
        .g = "hello",
    };
    var values = Values.init(alloc);
    try values.appendStruct(alloc, s);
    defer values.deinit(alloc);
    // TODO: gets allocated for wrting a msg but isn't when reading
    // so we either need to allocate the read or find an alternate
    // when writing
    alloc.free(values.values.items[0].slice.?);
    assert(values.values.items[0].inner.@"struct".len() == 7);
}

fn nestArray(alloc: Allocator, depth: u8) Values {
    if (depth == 0) return blk: {
        var v = Values.init(alloc);
        v.append(.{ .type = .byte, .inner = .{ .byte = 1 }}) catch unreachable;
        break :blk v;
    };
    var v = Values.init(alloc);
    v.append(.{
        .type = .array,
        .inner = .{ .array = nestArray(alloc, depth - 1) }
    }) catch unreachable;
    return v;
}

test "values arrays" {
    const alloc = std.testing.allocator;
    var values = Values.init(alloc);
    try values.append(.{
        .type = .array,
        .inner = .{ .array = nestArray(alloc, 10) },
        .contained_sig = "a" ** 9 ++ "y",
        .slice = &[_]u8{}
    });
    values.deinit(alloc);
}

fn nestStruct(alloc: Allocator, depth: u8) Values {
    if (depth == 0) return blk: {
        var v = Values.init(alloc);
        v.append(.{ .type = .byte, .inner = .{ .byte = 1 }}) catch unreachable;
        break :blk v;
    };
    var v = Values.init(alloc);
    v.append(.{
        .type = .@"struct",
        .inner = .{ .@"struct" = nestStruct(alloc, depth - 1) }
    }) catch unreachable;
    return v;
}

test "values structs" {
    const alloc = std.testing.allocator;
    var values = Values.init(alloc);
    try values.append(.{
        .type = .@"struct",
        .inner = .{ .@"struct" = nestStruct(alloc, 10) },
        .contained_sig = "(" ** 9 ++ "y" ++ ")" ** 9,
        .slice = &[_]u8{}
    });
    values.deinit(alloc);
}

test "values dict" {
    const alloc = std.testing.allocator;
    var values = Values.init(alloc);
    var dict = Values.init(alloc);
    try dict.append(.{ .type = .byte, .inner = .{ .byte = 1 }});
    try dict.append(.{ .type = .byte, .inner = .{ .byte = 0 }});
    try values.append(.{
        .type = .dict_entry,
        .inner = .{ .dict_entry = dict },
        .contained_sig = "{(y)(y)}",
        .slice = &[_]u8{}
    });
    values.deinit(alloc);
}

