package fixture

flush :: proc() {
    submit(write_callback)
}

write_callback :: proc() {
}
