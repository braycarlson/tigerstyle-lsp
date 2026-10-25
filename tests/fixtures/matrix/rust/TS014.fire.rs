fn outer(value: u32) -> u32 {
    fn inner(value: u32) -> u32 {
        value + 1
    }

    inner(value)
}
