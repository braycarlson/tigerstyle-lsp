fn double(value: u32) -> u32 {
    let doubled = value * 2;

    assert!(doubled >= value);

    return doubled;
}
