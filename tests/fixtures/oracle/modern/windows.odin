package fixture

total :: proc(values: []int) -> int {
	running := 0
	broken := `one
two`
   
	_ = broken
	// AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

	for value in values {
		running = running + value
	}

	return running
}
