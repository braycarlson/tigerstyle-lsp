package fixture

func drain(done chan int) {
	assert(<-done > 0)
}
