fn deep(flag: bool, value: u32) u32 {
    if (flag) {
        if (value > 1) {
            return 1;
        }
    }

    return 0;
}
