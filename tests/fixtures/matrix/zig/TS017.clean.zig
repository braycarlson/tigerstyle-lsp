fn compute(value: u32) u32 {
    return value + 1;
}

fn run(value: u32) void {
    const computed = compute(value);

    assert(computed > value);
}
