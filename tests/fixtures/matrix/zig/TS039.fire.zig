fn classify(value: u32) u32 {
    if (value == 0) {
        return 0;
    } else if (value == 1) {
        return 1;
    } else if (value == 2) {
        return 2;
    } else if (value == 3) {
        return 3;
    } else {
        return 4;
    }
}
