import ctypes


def read(value: int) -> int:
    address = ctypes.c_void_p(value)
    return address.value
