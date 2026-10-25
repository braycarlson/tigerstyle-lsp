package fixture

deep :: proc(a: bool, b: bool, c: bool) {
    if a {
        if b {
            if c {
                cleanup()
            }
        }
    }
}
