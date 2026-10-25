fn read() -> u32 {
    let address: *const u32 = core::ptr::null();

    address as u32
}
