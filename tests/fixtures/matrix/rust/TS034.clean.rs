fn run(value: u32, handler: impl Fn(u32)) {
    handler(value);
}
