def compute(value):
    return value + 1


def run(value):
    computed = compute(value)
    assert computed > value
