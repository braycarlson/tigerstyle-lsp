const std = @import("std");

fn run() void {
    var held = std.fifo.LinearFifo(u8, .{ .Static = 16 }).init();
    _ = &held;
}
