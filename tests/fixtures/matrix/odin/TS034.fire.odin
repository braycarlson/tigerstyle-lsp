package fixture

run :: proc(handler: proc(int), name: string) {
    handler(len(name))
}
