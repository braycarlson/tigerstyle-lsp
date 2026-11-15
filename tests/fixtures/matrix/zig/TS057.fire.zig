fn flush() void {
    submit(write_callback);
}

fn write_callback() void {}
