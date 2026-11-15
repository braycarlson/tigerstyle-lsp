fn total(values: []const u32) u32 {
    var sum: u32 = 0;
    for (values) |value| {
        sum += value;
    }
    return sum;
}
