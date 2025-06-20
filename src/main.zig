const std = @import("std");
const lib = @import("libdbuz");
const ArgIterator = std.process.ArgIterator;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var iter = try ArgIterator.initWithAllocator(allocator);
    _ = iter.skip(); // skip the program name
    const arg = iter.next();

    if (arg) |a| {
        if (std.mem.eql(u8, a, "client")) {
            try lib.runClient();
            return;
        }
    }

    try lib.eventLoop();
}
