const std = @import("std");
const lib = @import("libdbuz");

pub fn main() !void {
    try lib.eventLoop();
}
