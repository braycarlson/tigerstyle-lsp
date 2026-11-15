package fixture

import "os"

func run(path string) error {
	_, err := os.Open(path)
	if err != nil {
		return err
	}

	return nil
}
