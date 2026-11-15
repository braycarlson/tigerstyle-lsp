fn inner(value: u32) -> u32 {
    value + 1
}

fn outer(value: u32) -> u32 {
    inner(value)
}
