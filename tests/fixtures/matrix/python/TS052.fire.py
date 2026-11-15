def run():
    try:
        work()
    except AssertionError:
        return None
