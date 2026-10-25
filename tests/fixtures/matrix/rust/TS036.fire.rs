fn drain(values: &mut Vec<u32>) {
    assert!(values.pop().is_some());
}
