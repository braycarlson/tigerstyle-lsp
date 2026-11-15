fn load(buffer: []u32, count: usize) []u32 {
    assert(count <= buffer.len);

    return buffer[0..count];
}
