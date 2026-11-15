package fixture

run :: proc(value: int, handler: proc(int)) {
    handler(value)
}
