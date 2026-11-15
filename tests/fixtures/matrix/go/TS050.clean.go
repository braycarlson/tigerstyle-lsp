package fixture

func walk(depth int) {
	if depth > 0 {
		// tigerstyle-ignore: TS001
		walk(depth - 1)
	}
}
