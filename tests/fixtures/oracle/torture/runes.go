package fixture

func runes() int {
	plain := 'a'
	quoted := '\''
	wide := '\U0001F600'
	broken := '\n'
	hexadecimal := '\x41'
	stray := 'don't
	return int(plain) + int(quoted) + int(wide) + int(broken) + int(hexadecimal) + len(stray)
}
