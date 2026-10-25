package fixture

func compute(value int) int {
	return value + 1
}

func run(value int) int {
	computed := compute(value)

	return computed
}
