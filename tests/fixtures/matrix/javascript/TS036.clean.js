function drain(values) {
    assert(later((value) => value.count++ > 0));
}
