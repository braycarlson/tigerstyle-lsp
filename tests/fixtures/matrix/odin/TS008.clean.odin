package fixture

deep :: proc(a: bool, b: bool, c: bool) {
    if a && b && c {
        cleanup()
    }
}
