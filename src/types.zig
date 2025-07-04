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

    pub inline fn fromType(T: type) @This() {
        comptime {
            const t_info = @typeInfo(T);
            return switch (t_info) {
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
            const t_info = @typeInfo(T);
            return switch (t_info) {
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
                .pointer => |p| blk: {
                    if (p.is_const and p.child == u8) {
                        break :blk "s"; // we assume const u8 slices are strings
                    }
                    switch (p.size) {
                        .one => return signatureFromType(p.child),
                        .many => return null, // we don't support many pointers
                        // .slice => {
                        //     const sig = TypeSignature.fromType(p.child);
                        //     if (sig == .null) return null; // we don't support null slices
                        //     break :blk "a" ++ sig.?; // we assume slices are arrays
                        // },
                        .c => return null,
                    }
                },
                .array => |a| "a" ++ signatureFromType(a.child).?,
                .@"struct" => |s| blk: {
                    var fields: []const u8 = "";
                    for (s.fields) |f| {
                        fields = fields ++ (signatureFromType(f.type) orelse "");
                    }
                    break :blk "(" ++ fields ++ ")";
                },
                .error_union => |e| signatureFromType(e.payload),
                else => null,
            };
        }
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
    allocated: bool = false,
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
                if (value.allocated) alloc.free(value.slice.?);
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

    pub fn appendSliceOfValues(self: *Self, slice: []const Value) !void {
        try self.values.appendSlice(slice);
    }

    /// Append a new value to the values array.
    pub fn append(self: *Values, value: Value) !void {
        try self.values.append(value);
    }

    pub fn appendAnyType(self: *Values, alloc: Allocator, value: anytype) !void {
        try switch(@typeInfo(@TypeOf(value))) {
            // .type => values.append(.{}),
            // .void => values.append(.{}),
            .bool => self.appendBool(value),
            // .noreturn => values.append(.{}),
            .int => self.appendInt(value),
            .float => self.appendFloat(value),
            .pointer => self.appendPointer(alloc, value),
            .array => self.appendArray(alloc, value),
            .@"struct" => self.appendStruct(alloc, value),
            // .comptime_float => self.values.append(.{}),
            // .comptime_int => self.values.append(.{}),
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

    pub fn appendBool(self: *Self, value: bool) !void {
        try self.append(.{ .type = .boolean, .inner = .{ .boolean = value } });
    }

    pub fn appendInt(self: *Self, value: anytype) !void {
        const int_info = @typeInfo(@TypeOf(value));
        assert(int_info == .int);
        const i = int_info.int;
        try self.append(.{
            .type = TypeSignature.fromType(@TypeOf(value)),
            .inner = switch (i.bits) {
                0...8 => .{ .byte = @as(u8, value) },
                9...16 => if (i.signedness == .unsigned) .{ .uint16 = @as(u16, value) }
                          else .{ .int16 = @as(i16, value) },
                17...32 => if (i.signedness == .unsigned) .{ .uint32 = @as(u32, value) }
                          else .{ .int32 = @as(i32, value) },
                33...64 => if (i.signedness == .unsigned) .{ .uint64 = @as(u64, value) }
                          else .{ .int64 = @as(i64, value) },
                else => @panic("invalid int, ints must be smaller than or equal to 64 bits")
            },
        });
    }

    pub fn appendFloat(self: *Self, value: anytype) !void {
        const float_info = @typeInfo(@TypeOf(value));
        assert(float_info == .float);
        try self.append(.{
            .type = TypeSignature.fromType(@TypeOf(value)),
            .inner = .{ .double = @as(f64, value) },
        });
    }

    pub fn appendPointer(self: *Self, alloc: Allocator, pointer: anytype) !void {
        const pointer_info = @typeInfo(@TypeOf(pointer));
        assert(pointer_info == .pointer);
        switch (pointer_info.pointer.size) {
            .one => try self.appendAnyType(alloc, pointer.*),
            .slice => blk: {
                // TOOD: should we always assume that a slice of const u8 is a string?
                if (pointer_info.pointer.child == u8 and pointer_info.pointer.is_const) {
                    try self.values.append(.{
                        .type = .string,
                        .inner = .{ .string = String{ .inner = pointer } },
                        .allocated = true,
                        .slice = pointer,
                    });
                    break :blk;
                }
                try self.appendSlice(alloc, pointer_info.pointer.child, pointer);
            },
            else => {},
        }
    }

    pub fn appendSlice(self: *Self, alloc: Allocator, Child: anytype, slice: []const Child) !void {
        const slice_info = @typeInfo(@TypeOf(slice));
        assert(slice_info == .array);
        const sig = TypeSignature.signatureFromType(@TypeOf(slice));
        var slice_values = Values.init(alloc);
        for (slice) |item| {
            try slice_values.appendAnyType(alloc, item);
        }
        try self.append(.{
            .type = .array,
            .inner = .{ .array = slice_values },
            .contained_sig = sig,
        });
    }

    pub fn appendArray(self: *Self, alloc: Allocator, array: anytype) !void {
        const array_info = @typeInfo(@TypeOf(array));
        assert(array_info == .array);
        const sig = TypeSignature.signatureFromType(@TypeOf(array));

        var array_values = Values.init(alloc);
        for (array) |item| {
            try array_values.appendAnyType(alloc, item);
        }
        try self.append(.{
            .type = .array,
            .inner = .{ .array = array_values },
            .contained_sig = sig,
        });
    }

    pub fn appendStruct(self: *Self, alloc: Allocator, @"struct": anytype) !void {
        const struct_info = @typeInfo(@TypeOf(@"struct"));
        assert(struct_info == .@"struct");
        const sig = TypeSignature.signatureFromType(@TypeOf(@"struct"));

        var buf = ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        const buf_writer = buf.writer();

        var struct_values = Values.init(alloc);
        errdefer struct_values.deinit(alloc);

        inline for (@typeInfo(@TypeOf(@"struct")).@"struct".fields) |f| {
            const value = @field(@"struct", f.name);
            try struct_values.appendAnyType(alloc, value);
            _ = try writeBytesWithEndian(@TypeOf(value), buf_writer.any(), buf.items.len, value, .little);
        }

        try self.append(.{
            .type = .@"struct",
            .inner = .{ .@"struct" = struct_values },
            .contained_sig = sig,
            .allocated = true,
            .slice = try buf.toOwnedSlice()
        });
    }

    // TODO: this should be used for writing all values to a Dbus message
    fn writeBytesWithEndian(comptime T: type, w: Writer, pos: usize, v: T, endianness: Endian) !usize {
        const swap = builtin.target.cpu.arch.endian() != endianness;
        var i = pos;
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                try w.writeByteNTimes(0x00, TypeSignature.@"struct".alignOffset(i));
                inline for (struct_info.fields) |f| {
                    if (struct_info.backing_integer) |Int| {
                        const bytes =
                            if (swap) std.mem.toBytes(@byteSwap(@as(Int, @bitCast(@field(v, f.name)))))
                            else std.mem.toBytes(@as(Int, @bitCast(@field(v, f.name))));
                        try w.writeAll(&bytes);
                        i += bytes.len;
                    } else {
                        i += try writeBytesWithEndian(f.type, w, i, @field(v, f.name), endianness);
                    }
                }
            },
            .array => {
                try w.writeByteNTimes(0x00, TypeSignature.fromType(@TypeOf(v[0])).alignOffset(i));
                if (swap) {
                    try w.writeInt(
                        u32,
                        @as(u32, v.len),
                        if (builtin.target.cpu.arch.endian() == .little) .big else .little,
                    );
                } else {
                    try w.writeInt(u32, @as(u32, @sizeOf(@TypeOf(v))), builtin.target.cpu.arch.endian());
                }
                for (v) |item| {
                    i += try writeBytesWithEndian(@TypeOf(item), w, i, item, endianness);
                }
            },
            .@"enum" => {
                const bytes =
                    if (swap) std.mem.toBytes(@byteSwap(@intFromEnum(v)))
                    else std.mem.toBytes(@intFromEnum(v));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .bool => {
                const bytes =
                    if (swap) std.mem.toBytes(@byteSwap(@as(u32, @intFromBool(v))))
                    else std.mem.toBytes(@as(u32, @intFromBool(v)));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .float => |float_info| {
                const bytes =
                    if (swap) std.mem.toBytes(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(v))))
                    else std.mem.toBytes(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(v)));
                try w.writeAll(&bytes);
                i += bytes.len;
            },
            .pointer => |p| switch (p.size) {
                .one => i += try writeBytesWithEndian(p.child, w, i, v.*, endianness),
                .slice => {}, // i += try writeBytes([v.len]u8, w, i, v.*),
                .c, .many => {},
            },
            else => {
                const bytes = if (swap) std.mem.toBytes(@byteSwap(v)) else std.mem.toBytes(v);
                try w.writeAll(&bytes);
                i += bytes.len;
            },
        }
        return i;
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

