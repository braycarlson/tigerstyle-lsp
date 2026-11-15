package fixture

main :: proc() {
    assert(helper() == 1)
}

helper :: proc() -> int {
    return 1
}
