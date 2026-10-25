package fixture

outer :: proc() {
    inner :: proc() {
    }

    inner()
}
