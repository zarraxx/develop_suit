#!/usr/bin/env python3

import urllib.request


def main() -> None:
    request = urllib.request.Request(
        "https://www.google.com",
        headers={"User-Agent": "stage_python smoke test"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read(256)
        print(f"status={response.status}")
        if response.status != 200:
            raise SystemExit("unexpected HTTP status")
        if not body:
            raise SystemExit("empty HTTP response body")


if __name__ == "__main__":
    main()
