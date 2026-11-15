package fixture

import "os"

func run(path string) {
	_, err := os.Open(path)
	if err != nil {
	}
}
