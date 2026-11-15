def deep(first, second, third):
    with first:
        with second:
            with third:
                return 1
    return 0
