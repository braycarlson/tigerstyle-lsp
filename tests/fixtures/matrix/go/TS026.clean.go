package fixture

func double(value int) int {
	doubled := value * 2
	assert(doubled >= value)

	return doubled
}
