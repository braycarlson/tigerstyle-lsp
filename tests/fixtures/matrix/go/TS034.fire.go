package fixture

func run(handler func(int), name string) {
	handler(len(name))
}
