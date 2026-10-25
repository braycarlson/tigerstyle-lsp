const std = @import("std");

fn run() void {
    var held = std.fifo.LinearFifo(u8, .Dynamic).init(std.heap.page_allocator);
    _ = &held;
}
