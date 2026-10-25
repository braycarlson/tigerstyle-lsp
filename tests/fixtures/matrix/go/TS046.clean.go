package fixture

import "os"

func run(path string) error {
	name := path

	file, err := os.Open(name)
	defer file.Close()

	if err != nil {
		return err
	}

	return nil
}
