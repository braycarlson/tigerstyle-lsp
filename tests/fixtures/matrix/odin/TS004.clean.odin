package fixture

total :: proc(left: int, right: int) -> int {
    assert(left >= 0)
    if right < 0 {
        panic("negative")
    }

    first := left
    second := right
    sum := first + second

    return sum
}
