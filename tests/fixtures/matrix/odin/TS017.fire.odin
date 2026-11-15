package fixture

compute :: proc(value: int) -> int {
    return value + 1
}

run :: proc(value: int) {
    compute(value)
}
