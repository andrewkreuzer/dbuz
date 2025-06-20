const std = @import("std");
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const MemoryPool = std.heap.MemoryPool;

const xev = @import("xev");
const ReadBuffer = xev.ReadBuffer;
const WriteBuffer = xev.WriteBuffer;

pub const message = @import("message.zig");
pub const BusInterface = @import("interface.zig").BusInterface;
pub const Dbus = @import("dbus.zig").Dbus;
pub const Message = message.Message;
pub const ObjectPath = @import("types.zig").ObjectPath;

test {
    const builtin = @import("builtin");
    _ = @import("message.zig");

    switch (builtin.os.tag) {
        .linux => {
            _ = @import("dbus.zig");
            _ = @import("interface.zig");
        },
        else => {} // no support for other OSes yet
    }
}
