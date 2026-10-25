package fixture

double :: proc(value: int) -> int {
    result := value * 2

    assert(result >= value)

    return result
}
