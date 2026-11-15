from typing import Callable


def run(value: int, handler: Callable) -> None:
    handler(value)
