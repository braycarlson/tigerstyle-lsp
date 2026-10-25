def load(path):
    try:
        return open(path)
    except:
        return None
