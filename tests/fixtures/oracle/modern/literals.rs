fn main() {
    let plain = c"say";
    let raw = cr#"say "hi""#;
    let byte = b"say";
    let wide = r#########"deep"#########;
    let face = '\u{01_F600}';
    let hex = 0x1e - 1;
    let name = r#fn;
    println!("{plain:?} {raw:?} {byte:?} {wide} {face} {hex} {name}");
}
