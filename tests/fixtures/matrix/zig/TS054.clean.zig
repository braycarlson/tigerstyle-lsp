const std = @import("std");

fn run(value: u32) void {
    std.debug.assert(value > 0);
    work(value);
}
