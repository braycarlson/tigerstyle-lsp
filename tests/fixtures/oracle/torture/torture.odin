#+build linux, darwin, windows
package fixture

import "core:strings"

carriage := `one
two`

total :: proc(values: []int) -> int {
	running := 0

	for value in values {
		if value < 0 do continue
		if value == 0 do break

		running += value
	}

	joined := "one \ 
		two"

	return running + strings.index(joined, carriage)
}
