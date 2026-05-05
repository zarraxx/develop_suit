#!/bin/sh

set -eu

READELF="$1"
BASH_BIN="$2"

needed="$("$READELF" -d "$BASH_BIN")"

for library in libreadline.so libhistory.so libncursesw.so; do
  if ! printf '%s\n' "$needed" | grep -q "Shared library: \\[${library}"; then
    echo "error: bash is not linked against ${library}" >&2
    exit 1
  fi
done

echo "-- bash links external readline/history/ncursesw"
