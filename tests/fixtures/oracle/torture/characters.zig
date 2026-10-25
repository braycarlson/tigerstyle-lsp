pub fn characters() u32 {
    const plain = 'a';
    const quoted = '\'';
    const wide = '\u{1F600}';
    const broken = '\n';
    const hexadecimal = '\x41';
    const stray = 'don't;
    return plain + quoted + wide + broken + hexadecimal + stray;
}
