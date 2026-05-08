#!/usr/bin/env python3

import multiprocessing


def worker(value: int, queue: multiprocessing.Queue) -> None:
    queue.put(value * value)


def main() -> None:
    ctx = multiprocessing.get_context("fork")
    queue = ctx.Queue()
    process = ctx.Process(target=worker, args=(12, queue))
    process.start()
    process.join(timeout=10)

    if process.is_alive():
        process.terminate()
        process.join()
        raise SystemExit("multiprocessing worker timed out")

    if process.exitcode != 0:
        raise SystemExit(f"multiprocessing worker failed: {process.exitcode}")

    result = queue.get(timeout=5)
    print(f"process_result={result}")
    if result != 144:
        raise SystemExit("multiprocessing result mismatch")


if __name__ == "__main__":
    main()
