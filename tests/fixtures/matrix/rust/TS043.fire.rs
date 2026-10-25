fn run(value: u32) -> u32 {
    let first = value;
    let second = value + 1;
    let third = value + 2;
    let fourth = value + 3;

    assert!(second > 0);
    assert!(third > 0);
    assert!(fourth > 0);

    first
}
