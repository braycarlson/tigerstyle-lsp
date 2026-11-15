package fixture

walk :: proc(depth: int) {
    if depth > 0 {
        // tigerstyle-ignore: TS001
        walk(depth - 1)
    }
}
