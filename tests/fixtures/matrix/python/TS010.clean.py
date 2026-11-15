def load(path):
    try:
        return open(path)
    except OSError:
        raise
