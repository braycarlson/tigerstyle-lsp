package fixture

func increment(amount int) int {
	return amount + 1
}

func run(value int) int {
	return increment(value)
}
