def outer(value):
    def inner(amount):
        return amount + 1

    return inner(value)
