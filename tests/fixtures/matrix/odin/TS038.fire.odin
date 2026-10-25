package fixture

pick :: proc(flag: bool) -> int {
    if !flag {
        return 1
    } else {
        return 2
    }
}
