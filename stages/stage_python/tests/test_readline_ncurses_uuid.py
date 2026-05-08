#!/usr/bin/env python3

import curses
import readline
import uuid


def main() -> None:
    readline.parse_and_bind("tab: complete")
    readline.add_history("stage_python smoke test")

    curses.setupterm()
    clear_cap = curses.tigetstr("clear")
    if clear_cap is None:
        raise SystemExit("ncurses terminfo lookup failed")

    generated = uuid.uuid4()
    print(f"uuid={generated}")
    print(f"clear_cap_len={len(clear_cap)}")
    print(f"history_length={readline.get_current_history_length()}")


if __name__ == "__main__":
    main()
