def load(path):
    try:
        return open(path)
    except Exception:
        pass
