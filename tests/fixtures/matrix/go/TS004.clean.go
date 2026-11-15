package fixture

func total(left int, right int) int {
	assert(left < 100)
	if right < 0 {
		panic("negative")
	}
	sum := left + right

	return sum
}
