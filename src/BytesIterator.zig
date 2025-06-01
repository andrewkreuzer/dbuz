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
        .signature => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u8)];
            const len = mem.readInt(u8, slice, .little);
            const ret = self.buffer[alignment+@sizeOf(u8)..][0..len];
            const n = offset + len + @sizeOf(u8) + 1; // 1 for null byte
            break :blk .{ ret, n };
        },
        .variant => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u8)];
            const len = mem.readInt(u8, slice, .little);
            const ret = self.buffer[alignment+@sizeOf(u8)..][0..len];
            const n = offset + len + @sizeOf(u8) + 1; // 1 for null byte
            break :blk .{ ret, n }; // 1 for null byte
        },
        .object_path, .string => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u32)];
            const len = mem.readInt(u32, slice, .little);
            const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
            const n = offset + len + @sizeOf(u32) + 1;
            break :blk .{ ret, n }; // 1 for null byte
        },
        .array => blk: {
            const slice = self.buffer[alignment..][0..@sizeOf(u32)];
            const len = mem.readInt(u32, slice, .little);
            const offset_ = t.?.alignOffset(alignment + @sizeOf(u32));
            alignment += offset_;
            const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
            const n = offset + offset_ + len + @sizeOf(u32) + 1;
            break :blk .{ ret, n };
        },
        .@"struct", .dict_entry  => .{ self.buffer[alignment..], offset },
        else =>  null,
    };
}

