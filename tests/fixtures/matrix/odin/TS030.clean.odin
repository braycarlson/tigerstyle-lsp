package fixture

run :: proc(flag: bool, value: int) -> int {
    if flag do return value

    return 0
}
