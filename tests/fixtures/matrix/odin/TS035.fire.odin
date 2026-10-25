package fixture

platform :: proc() -> int {
    when ODIN_OS == .Linux {
        return 1
    }

    return 0
}
