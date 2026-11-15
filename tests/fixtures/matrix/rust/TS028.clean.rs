fn load() -> Result<u32, u32> {
    Ok(1)
}

fn run() {
    let loaded = load().expect("the value loads");

    assert!(loaded > 0);
}
