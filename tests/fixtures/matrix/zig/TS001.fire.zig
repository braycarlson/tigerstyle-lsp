fn walk(depth: u32) void {
    if (depth > 0) {
        walk(depth - 1);
    }
}
