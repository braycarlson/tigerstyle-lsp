package fixture

func deep(flag bool, value int) int {
	if flag {
		if value > 0 {
			if value > 1 {
				return 1
			}
		}
	}

	return 0
}
