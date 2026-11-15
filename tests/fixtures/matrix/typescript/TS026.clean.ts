function double(value: number): number {
    const result = value * 2;

    assert(result >= value);

    return result;
}
