fn run(allocator: Allocator, count: usize) !void {
    assert(count > 0);

    const buffer = try allocator.alloc(u32, count);
    defer allocator.free(buffer);

    assert(buffer.len == count);
}
