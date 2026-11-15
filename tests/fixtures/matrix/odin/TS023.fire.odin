package fixture

pick :: proc(first: bool, second: bool, third: bool) -> int {
    if first && second || third {
        return 1
    }

    return 0
}
