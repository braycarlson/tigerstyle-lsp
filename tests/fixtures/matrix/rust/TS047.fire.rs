fn check(flag: bool, value: u32) {
    if flag {
        // value follows flag
        assert!(value > 0);
    }
}
