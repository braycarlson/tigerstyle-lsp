package fixture

func run(value int) int {
	if value > 0 {
		goto done
	}

done:
	return value
}
