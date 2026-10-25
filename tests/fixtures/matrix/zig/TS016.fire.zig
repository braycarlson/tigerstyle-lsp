fn load(allocator: Allocator, count: usize) ![]u32 {
    const buffer = try allocator.alloc(u32, count);

    return buffer;
}
