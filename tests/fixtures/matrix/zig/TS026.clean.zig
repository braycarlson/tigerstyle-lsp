fn double(value: u32) u32 {
    const doubled = value * 2;

    assert(doubled >= value);

    return doubled;
}
