fn scale(value: &u32, held: &mut Reader) -> u32 {
    held.read(*value)
}
