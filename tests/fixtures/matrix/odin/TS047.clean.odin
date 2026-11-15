package fixture

check :: proc(flag: bool, value: int) {
    assert(!flag || value > 0)
}
