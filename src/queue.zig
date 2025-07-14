const std = @import("std");
const assert = std.debug.assert;

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        capacity: usize,
        size: usize = 0,

        pub fn init(cap: usize) Self {
            return Self{
                .capacity = cap,
            };
        }

        pub fn push(self: *Self, e: *T) !void {
            if (self.size == self.capacity) {
                return error.QueueFull;
            }

            assert(e.next == null);
            if (self.tail) |tail| {
                tail.next = e;
                self.tail = e;
            } else {
                self.head = e;
                self.tail = e;
            }

            self.size += 1;
        }

        pub fn pop(self: *Self) ?*T {
            const next = self.head orelse return null;

            if (self.head == self.tail) self.tail = null;

            self.head = next.next;
            self.size -= 1;

            next.next = null;
            return next;
        }

        pub fn empty (self: *Self) bool {
            return self.size == 0;
        }
    };
}

test "queue" {
    const Entry = struct {
        const Self = @This();
        next: ?*Self = null,
    };

    const capacity = 5;
    var queue = Queue(Entry).init(capacity);

    var entries: [5]Entry = .{Entry{}} ** 5;
    try queue.push(&entries[0]);
    try std.testing.expect(queue.pop().? == &entries[0]);

    try std.testing.expect(queue.empty());

    try queue.push(&entries[0]);
    try queue.push(&entries[1]);
    try std.testing.expect(queue.pop().? == &entries[0]);
    try std.testing.expect(queue.pop().? == &entries[1]);

    try std.testing.expect(queue.empty());

    try queue.push(&entries[0]);
    try std.testing.expect(queue.pop().? == &entries[0]);
    try queue.push(&entries[1]);
    try std.testing.expect(queue.pop().? == &entries[1]);

    try std.testing.expect(queue.empty());
}

test "full" {
    const Entry = struct {
        const Self = @This();
        next: ?*Self = null,
    };

    const capacity = 2;
    var queue = Queue(Entry).init(capacity);
    try std.testing.expect(queue.empty());

    var entries: [3]Entry = .{Entry{}} ** 3;
    try queue.push(&entries[0]);
    try queue.push(&entries[1]);

    try std.testing.expectError(error.QueueFull, queue.push(&entries[2]));
}
