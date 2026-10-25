package fixture

drain :: proc(values: ^[dynamic]int) {
    value := pop(values)

    assert(value > 0)
}
