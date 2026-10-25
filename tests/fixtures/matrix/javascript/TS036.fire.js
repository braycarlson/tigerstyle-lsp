function drain(values) {
    assert(values.filter((value) => value.count++ > 0).length);
}
