package fixture

func check(flag bool, value int) {
	if flag {

		assert(value > 0)
	}
}
