package fixture

func flush() {
	submit(writeCallback)
}

func writeCallback() {
}
