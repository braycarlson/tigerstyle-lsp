package fixture

run :: proc(value: int) -> int {
    first := value

    report(value)
    report(value)
    report(value)
    report(value)
    report(value)
    report(value)

    return first
}
