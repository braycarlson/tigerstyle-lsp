package fixture

Range :: struct {
    start: int,
    end: int,
}

span :: proc(range: Range) -> int {
    return range.end - range.start
}
