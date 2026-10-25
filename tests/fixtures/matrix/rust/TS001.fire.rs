fn walk(depth: u32) {
    if depth > 0 {
        walk(depth - 1);
    }
}
