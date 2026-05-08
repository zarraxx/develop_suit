#!/usr/bin/env python3

import ctypes


def main() -> None:
    libc = ctypes.CDLL("libc.so.6")
    libc.puts.argtypes = [ctypes.c_char_p]
    libc.puts.restype = ctypes.c_int
    result = libc.puts(b"hello world from ctypes")
    print(f"puts_result={result}")
    if result < 0:
        raise SystemExit("puts failed")


if __name__ == "__main__":
    main()
