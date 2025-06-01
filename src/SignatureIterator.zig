const SignatureIterator = @import("SignatureIterator.zig");
const TypeSignature = @import("types.zig").TypeSignature;

buffer: []const u8,
index: usize = 0,

const Self = @This();

pub fn next(self: *Self) ?u8 {
    const result = self.peek() orelse return null;
    self.index += 1;
    return result;
}

pub fn peek(self: *Self) ?u8 {
    if (self.index >= self.buffer.len) return null;
    return self.buffer[self.index];
}

pub fn rest(self: *Self) []const u8 {
    return self.buffer[self.index..];
}

pub fn advance(self: *Self, n: usize) void {
    self.index += n;
}

pub fn readContainerSignature(
    self: *Self,
    T: TypeSignature,
) !?[]const u8 {
    const start = self.index;
    var i: usize = 1;
    var stack: [64]u8 = undefined;
    switch (T) {
        .@"struct" => stack[0] = ')',
        .dict_entry => stack[0] = '}',
        .array => i -= 1,
        else => return null,
    }

    while (self.next()) |c| {
        const s = if (i > 0) stack[i-1] else 0;
        switch (c) {
            'a' => continue,
            ')', '}' => |b| {
                if (s == b) i -= 1 else return error.InvalidSignature;
                if (i == 0 and (T == .@"struct" or T == .dict_entry)) {
                    const end = self.index-1;
                    return self.buffer[start..end];
                }
            },
            '(' => {
                if (i >= stack.len) return error.SignatureMaxDepth;
                stack[i] = ')';
                i += 1;
            },
            '{' => {
                if (i >= stack.len) return error.SignatureMaxDepth;
                stack[i] = '}';
                i += 1;
            },
            else => {}
        }
        if (i == 0) { const end = self.index; return self.buffer[start..end]; }
    } else return error.InvalidSignature;
}

test "container signatures" {
    const std = @import("std");
    const cases = [_]struct {
        t: TypeSignature,
        sig: []const u8,
        expected: []const u8
    }{
        .{ .t = .array, .sig = "yaai", .expected = "y" },
        .{ .t = .array, .sig = "ayuu", .expected = "ay" },
        .{ .t = .array, .sig = "{ay}yy", .expected = "{ay}" },
        .{ .t = .array, .sig = "{a{ay}}aay", .expected = "{a{ay}}" },
        .{ .t = .array, .sig = "{a{a{ay}}}uu", .expected = "{a{a{ay}}}" },
        .{ .t = .array, .sig = "{a{a{a{ay}}}}xx", .expected = "{a{a{a{ay}}}}" },
        .{ .t = .@"struct", .sig = "sas)", .expected = "sas" },
        .{ .t = .dict_entry, .sig = "sa}", .expected = "sa" },
    };
    for (cases) |c| {
        var iter = SignatureIterator{ .buffer = c.sig };
        const contained_sig = try iter.readContainerSignature(c.t);
        try std.testing.expectEqualSlices(u8, c.expected, contained_sig.?);
    }
}

