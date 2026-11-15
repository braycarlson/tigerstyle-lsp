package fixture

run :: proc(values: []int, index: int) -> int {
    assert(index >= 0)

    return values[index]
}
