fn drain(values: *List) void {
    std.debug.assert(values.popOrNull() != null);
}
