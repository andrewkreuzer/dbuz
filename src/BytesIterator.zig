const std = @import("std");
const mem = std.mem;

const TypeSignature = @import("types.zig").TypeSignature;

buffer: []const u8,
index: usize = 0,

const Self = @This();

pub fn pos(self: *Self) usize {
    return self.index;
}

pub fn next(self: *Self, T: TypeSignature, t: ?TypeSignature) ?[]const u8 {
    const result, const n = self.peek(T, t) orelse return null;
    self.index += n;
    return result;
}

pub fn peek(self: *Self, T: TypeSignature, t: ?TypeSignature) ?struct{ []const u8, usize } {
    const offset = T.alignOffset(self.index);
    var alignment = self.index + offset;
    if (alignment >= self.buffer.len) return null;

    return switch (T) {
        .byte => .{
            self.buffer[alignment..][0..@sizeOf(u8)],
            offset + @sizeOf(u8)
        },
        .boolean => .{
            self.buffer[alignment..][0..@sizeOf(u32)],
            offset + @sizeOf(u32)
        },
        .int16 => .{
            self.buffer[alignment..][0..@sizeOf(i16)],
            offset + @sizeOf(i16)
        },
        .uint16 => .{
            self.buffer[alignment..][0..@sizeOf(u16)],
            offset + @sizeOf(u16)
        },
        .int32 => .{
            self.buffer[alignment..][0..@sizeOf(i32)],
            offset + @sizeOf(i32)
        },
        .uint32 => .{
            self.buffer[alignment..][0..@sizeOf(u32)],
            offset + @sizeOf(u32)
        },
        .int64 => .{
            self.buffer[alignment..][0..@sizeOf(i64)],
            offset + @sizeOf(i64)
        },
        .uint64 => .{
            self.buffer[alignment..][0..@sizeOf(u64)],
            offset + @sizeOf(u64)
        },
        .double => .{
            self.buffer[alignment..][0..@sizeOf(f64)],
            offset + @sizeOf(f64)
        },
        .string, .object_path  => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u32)];
            const len = mem.readInt(u32, slice, .little);
            const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
            const n = offset + len + @sizeOf(u32) + 1;
            break :blk .{ ret, n }; // 1 for null byte
        },
        .signature => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u8)];
            const len = mem.readInt(u8, slice, .little);
            const ret = self.buffer[alignment+@sizeOf(u8)..][0..len];
            const n = offset + len + @sizeOf(u8) + 1; // 1 for null byte
            break :blk .{ ret, n };
        },
        .array => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u32)];
            const len = mem.readInt(u32, slice, .little);
            const offset_ = t.?.alignOffset(alignment + @sizeOf(u32));
            alignment += offset_;
            const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
            const n = offset + offset_ + len + @sizeOf(u32);
            break :blk .{ ret, n };
        },
        .@"struct", .dict_entry  => .{ self.buffer[alignment..], offset },
        .variant => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u8)];
            const len = mem.readInt(u8, slice, .little);
            const ret = self.buffer[alignment+@sizeOf(u8)..][0..len];
            const n = offset + len + @sizeOf(u8) + 1; // 1 for null byte
            break :blk .{ ret, n };
        },
        else =>  null,
    };
}

test "peek" {
    const tests = [_]struct{
        name: []const u8,
        buffer: []const u8,
        index: usize,
        T: TypeSignature,
        t: ?TypeSignature = null,
        expected: ?struct{ []const u8, usize },
    }{
        .{ .name = "byte", .buffer = "a", .index = 0, .T = .byte, .t = null, .expected = .{ "a", 1 } },
        .{ .name = "boolean", .buffer = "\x01\x00\x00\x00", .index = 0, .T = .boolean, .t = null, .expected = .{ "\x01\x00\x00\x00", 4 } },
        .{ .name = "int16", .buffer = "\x01\x00", .index = 0, .T = .int16, .t = null, .expected = .{ "\x01\x00", 2 } },
        .{ .name = "uint16", .buffer = "\x01\x00", .index = 0, .T = .uint16, .t = null, .expected = .{ "\x01\x00", 2 } },
        .{ .name = "int32", .buffer = "\x01\x00\x00\x00", .index = 0, .T = .int32, .t = null, .expected = .{ "\x01\x00\x00\x00", 4 } },
        .{ .name = "uint32", .buffer = "\x01\x00\x00\x00", .index = 0, .T = .uint32, .t = null, .expected = .{ "\x01\x00\x00\x00", 4 } },
        .{ .name = "int64", .buffer = "\x01\x00\x00\x00\x00\x00\x00\x00", .index = 0, .T = .int64, .t = null, .expected = .{ "\x01\x00\x00\x00\x00\x00\x00\x00", 8 } },
        .{ .name = "uint64", .buffer = "\x01\x00\x00\x00\x00\x00\x00\x00", .index = 0, .T = .uint64, .t = null, .expected = .{ "\x01\x00\x00\x00\x00\x00\x00\x00", 8 } },
        .{ .name = "double", .buffer = "\x01\x00\x00\x00\x00\x00\x00\x00", .index = 0, .T = .double, .t = null, .expected = .{ "\x01\x00\x00\x00\x00\x00\x00\x00", 8 } },
        .{ .name = "string", .buffer = "\x04\x00\x00\x00test\x00", .index = 0, .T = .string, .t = null, .expected = .{ "test", 9 } },
        .{ .name = "object_path", .buffer = "\x04\x00\x00\x00test\x00", .index = 0, .T = .object_path, .t = null, .expected = .{ "test", 9 } },
        .{ .name = "signature", .buffer = "\x04test\x00", .index = 0, .T = .signature, .t = null, .expected = .{ "test", 6 } },
        .{ .name = "array", .buffer = "\x09\x00\x00\x00\x04\x00\x00\x00test\x00", .index = 0, .T = .array, .t = .string, .expected = .{ "\x04\x00\x00\x00test\x00", 13 } },
        .{ .name = "struct", .buffer = "\x07\x00\x00\x00\x08\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x04\x00\x00\x00\x01\x00\x02\x00", .index = 0, .T = .@"struct", .t = null, .expected = .{ "\x07\x00\x00\x00\x08\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x04\x00\x00\x00\x01\x00\x02\x00", 0 } },
        .{ .name = "variant", .buffer = "\x01s\x00\x05\x00\x00\x00test\x00", .index = 0, .T = .variant, .t = null, .expected = .{ "s", 3 } },
        .{ .name = "dict_entry", .buffer = "\x03\x01\x73\x00\x04\x00\x00\x00\x54\x65\x73\x74\x00", .index = 0, .T = .dict_entry, .t = null, .expected = .{ "\x03\x01\x73\x00\x04\x00\x00\x00\x54\x65\x73\x74\x00", 0 } },
        .{ .name = "invalid", .buffer = "test", .index = 0, .T = .byte, .t = null, .expected = null },

    };

    for (tests) |t| {
        var iter = Self{
            .buffer = t.buffer,
            .index = t.index,
        };
        const result = iter.peek(t.T, t.t);
        if (t.expected) |expected| if (result) |r| {
            try std.testing.expectEqualSlices(u8, expected.@"0", r.@"0");
            try std.testing.expectEqual(expected.@"1", r.@"1");
        } else {
            try std.testing.expect(t.expected == null);
        };
    }
}
