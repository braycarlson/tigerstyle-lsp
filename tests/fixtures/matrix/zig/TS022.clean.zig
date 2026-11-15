fn scale(comptime T: type, held: *Reader) T {
    return held.read(T);
}
