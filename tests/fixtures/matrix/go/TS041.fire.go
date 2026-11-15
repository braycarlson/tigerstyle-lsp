package fixture

func find(value int) (*int, bool, error) {
	return &value, true, nil
}
