fn run(value: u32) u32 {
    const first = value;
    const second = value + 1;
    const third = value + 2;
    const fourth = value + 3;

    assert(second > 0);
    assert(third > 0);
    assert(fourth > 0);

    return first;
}
