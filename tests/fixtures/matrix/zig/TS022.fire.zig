fn scale(values: []const u32, held: ?*Reader) u32 {
    return values[0] * 2 + held.?.count;
}
