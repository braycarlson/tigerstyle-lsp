package fixture

run :: proc(values: []int, index: int) -> int {
    #no_bounds_check {
        return values[index]
    }
}
