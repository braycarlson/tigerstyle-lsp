fn compute(value: u32) -> u32 {
    value + 1
}

fn run(value: u32) {
    let computed = compute(value);

    assert!(computed > value);
}
