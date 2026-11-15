from typing import Callable


def run(handler: Callable, value: int) -> None:
    handler(value)
