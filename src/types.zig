const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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
            // TODO: don't want to have to allocate these
            // when generating the message
            // alloc.free(value.contained_sig);
            // alloc.free(value.slice);
        }
        self.values.deinit();
    }

    pub fn len(self: *Values) usize {
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

    pub fn appendSlice(self: *Self, slice: []const Value) !void {
        try self.values.appendSlice(slice);
    }

    pub fn fromSlice(alloc: Allocator, slice: []const Value) !Values {
        var values = try ArrayList(Value).initCapacity(alloc, slice.len);
        values.insertSlice(0, slice) catch unreachable;
        return .{
            .values = values,
        };
    }
};

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

