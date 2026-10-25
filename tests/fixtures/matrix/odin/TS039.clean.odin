package fixture

classify :: proc(value: int) -> int {
    switch value {
    case 0:
        return 0
    case 1:
        return 1
    case 2:
        return 2
    }

    return 4
}
