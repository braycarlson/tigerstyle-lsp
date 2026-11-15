package fixture

pick :: proc(flag: bool) -> int {
    if flag {
        return 2
    } else {
        return 1
    }
}
