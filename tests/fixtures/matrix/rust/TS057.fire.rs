fn flush() {
    submit(write_callback);
}

fn write_callback() {}
