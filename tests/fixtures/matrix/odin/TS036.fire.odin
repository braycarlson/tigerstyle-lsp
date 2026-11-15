package fixture

drain :: proc(values: ^[dynamic]int) {
    assert(pop(values) > 0)
}
