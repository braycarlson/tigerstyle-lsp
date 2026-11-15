package fixture

walk :: proc(depth: int) {
    if depth > 0 {
        walk(depth - 1)
    }
}
