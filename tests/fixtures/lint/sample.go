package main

import . "fmt"

var counter = 0

func Helper(first, second, third, fourth, fifth, sixth, seventh, eighth int) int {
	for {
		if first > 0 && second > 0 {
			idx := 1
			counter = idx
		}
	}
}

func main() {
	double := func(value int) int {
		return value * 2
	}

	Println(double(counter))
}
