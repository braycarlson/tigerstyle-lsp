package fixture

helper :: proc() -> int {
    return 1
}

main :: proc() {
    assert(helper() == 1)
}
