fn walk(depth: u32) {
    if depth > 0 {
        // tigerstyle-ignore: TS001
        walk(depth - 1);
    }
}

// tigerstyle-disable: TS001
fn descend(depth: u32) {
    if depth > 0 {
        descend(depth - 1);
    }
}
// tigerstyle-enable: TS001
