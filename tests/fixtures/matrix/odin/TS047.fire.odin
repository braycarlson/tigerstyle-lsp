package fixture

check :: proc(flag: bool, value: int) {
    if flag {
        assert(value > 0)
    }
}
