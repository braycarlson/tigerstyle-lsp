package fixture

import "strings"

func labelled(values []int) int {
	running := 0 // The comment stands where the semicolon goes.

loop:
	for _, value := range values {
		switch {
		case value < 0:
			break loop
		case value == 0:
			continue loop
		}

		running += value // Another comment ahead of the closing brace.
	}

	return running + strings.Count(carriage, "\n")
}

var carriage = `one
two`

var trailing = 1 /* a block comment ahead of the newline */
