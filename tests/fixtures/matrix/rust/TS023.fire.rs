fn pick(first: bool, second: bool, third: bool) -> u32 {
    if first && second || third {
        return 1;
    }

    0
}
