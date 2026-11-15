package fixture

func pick(first bool, second bool) int {
	if first {
		return 1
	}

	if second {
		return 2
	}

	return 0
}
