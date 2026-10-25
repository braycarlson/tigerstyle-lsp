package fixture

run :: proc() {
    assert(true)

    value := new(int)
    defer free(value)

    assert(value != nil)
}
