package fixture

func run(flag bool, value int) int {
	held := value

	if flag {
		report(held)
	}

	return 0
}
