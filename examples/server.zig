const std = @import("std");
const log = std.log;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const xev = @import("xev");

const lib = @import("libdbuz");
const BusInterface = lib.BusInterface;
const Dbus = lib.Dbus;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var thread_pool = xev.ThreadPool.init(.{});
    var server = try Dbus(.server).init(.{
        .allocator = allocator,
        .thread_pool = &thread_pool
    });
    defer server.deinit();

    var guide: Guide = .{};
    const guide_iface = BusInterface(@TypeOf(server), Guide).init(&guide);
    try server.bind(guide_iface.interface());

    var planet: Planet = .{};
    const planet_iface = BusInterface(@TypeOf(server), Planet).init(&planet);
    try server.bind(planet_iface.interface());

    var empty: Empty = .{};
    const empty_iface = BusInterface(@TypeOf(server), Empty).init(&empty);
    try server.bind(empty_iface.interface());

    try server.start(.{});
    try server.run(.until_done);
}

const Guide = struct {
    name: []const u8 = "com.example.Guide",
    pub fn life( _: *@This()) !u32 {
        return 42;
    }
};

const Planet = struct {
    name: []const u8 = "com.example.Planet",
    pub fn hack( _: *@This()) !bool {
        return true;
    }
};

const Empty = struct {
    name: []const u8 = "com.example.Empty",
};
