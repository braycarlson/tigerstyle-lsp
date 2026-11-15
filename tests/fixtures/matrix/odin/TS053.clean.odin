package fixture

Options :: struct {
    limit: int,
}

run :: proc() {
    configure(Options{limit = 4})
}
