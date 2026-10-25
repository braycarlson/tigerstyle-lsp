fn walk(depth: u32) void {
    if (depth > 0) {
        // tigerstyle-ignore: TS001
        walk(depth - 1);
    }
}
