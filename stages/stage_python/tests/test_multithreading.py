#!/usr/bin/env python3

import queue
import threading


def worker(index: int, output: "queue.Queue[int]") -> None:
    output.put(index + 100)


def main() -> None:
    output: "queue.Queue[int]" = queue.Queue()
    threads = [threading.Thread(target=worker, args=(index, output)) for index in range(4)]

    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=5)
        if thread.is_alive():
            raise SystemExit("thread timed out")

    results = sorted(output.get(timeout=2) for _ in threads)
    print(f"thread_results={results}")
    if results != [100, 101, 102, 103]:
        raise SystemExit("thread result mismatch")


if __name__ == "__main__":
    main()
