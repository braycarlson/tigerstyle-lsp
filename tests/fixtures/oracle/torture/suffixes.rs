fn main() {
    let plain = "text";
    let counted = 1_000_i64;
    let wide = 1.5e-3_f64;
    let byte = b'x';
    let raw = r"a\b";
    let name = 0x1e - 1;
    println!("{plain} {counted} {wide} {byte:?} {raw} {name}");
}
