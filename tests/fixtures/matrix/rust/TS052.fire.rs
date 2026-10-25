fn run() {
    let _ = std::panic::catch_unwind(|| work());
}
