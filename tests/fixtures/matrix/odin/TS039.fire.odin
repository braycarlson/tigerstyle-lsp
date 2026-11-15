package fixture

classify :: proc(value: int) -> int {
    if value == 0 {
        return 0
    } else if value == 1 {
        return 1
    } else if value == 2 {
        return 2
    } else if value == 3 {
        return 3
    }

    return 4
}
