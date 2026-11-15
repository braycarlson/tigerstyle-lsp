fn run<F: Fn(u32)>(handler: F, name: &str) {
    handler(name.len() as u32);
}
