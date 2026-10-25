package fixture

func run(value int) int {
	increment := func(amount int) int {
		return amount + 1
	}

	return increment(value)
}
