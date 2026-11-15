package fixture

scale :: proc(value: int) -> int {
    assert(value >= 0)

    return value * 2
}
