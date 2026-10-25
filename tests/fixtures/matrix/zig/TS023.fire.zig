fn pick(first: bool, second: bool, third: bool) u32 {
    if (first and second or third) {
        return 1;
    }

    return 0;
}
