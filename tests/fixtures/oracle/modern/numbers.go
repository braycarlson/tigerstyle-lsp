package numbers

func Read() float64 {
	hex := 0xE - 1
	floating := 0x1.fp-2
	a := 1 /* note
	*/ b := a + hex
	return floating + float64(b)
}
