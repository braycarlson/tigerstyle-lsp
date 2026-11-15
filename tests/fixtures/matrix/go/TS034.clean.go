package fixture

func run(value int, handler func(int)) {
	handler(value)
}
