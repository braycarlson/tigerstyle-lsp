package fixture

func walk(depth int) {
	if depth > 0 {
		walk(depth - 1)
	}
}
