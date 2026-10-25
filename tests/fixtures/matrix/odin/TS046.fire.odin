package fixture

run :: proc() {
    value := new(int)
    defer free(value)
    assert(value != nil)
}
