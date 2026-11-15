package fixture

func scale(value int) int {
	assert(value < 100)

	return value * 2
}
