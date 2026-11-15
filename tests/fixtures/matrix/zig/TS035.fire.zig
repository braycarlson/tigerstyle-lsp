fn platform() u32 {
    if (builtin.os.tag == .linux) {
        return 1;
    }

    return 0;
}
