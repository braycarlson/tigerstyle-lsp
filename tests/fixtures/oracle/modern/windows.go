package fixture

func total(values []int) int {
	running := 0
	broken := `one
two`
	_ = broken
   
	// AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

	for _, value := range values {
		running = running + value
	}

	return running
}
