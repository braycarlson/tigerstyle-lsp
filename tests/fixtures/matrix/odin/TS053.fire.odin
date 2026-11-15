package fixture

Options :: struct {
    limit: int,
}

run :: proc() {
    configure(Options{})
}
