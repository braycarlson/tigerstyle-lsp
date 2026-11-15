package fixture

func run() {
	defer func() {
		_ = recover()
	}()
}
