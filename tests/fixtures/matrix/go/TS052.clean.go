package fixture

func run() {
	defer func() {
		cleanup()
	}()
}
