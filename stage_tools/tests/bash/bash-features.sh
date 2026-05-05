#!/usr/bin/env bash

set -euo pipefail

declare -A words=(
  [stage]=tools
  [shell]=bash
)

joined="${words[stage]}-${words[shell]}"

if [[ "$joined" != "tools-bash" ]]; then
  echo "unexpected associative array result: $joined" >&2
  exit 1
fi

mapfile -t lines < <(printf '%s\n' alpha beta gamma)

if [[ "${#lines[@]}" -ne 3 || "${lines[2]}" != "gamma" ]]; then
  echo "unexpected process substitution/mapfile result" >&2
  exit 1
fi

printf 'bash feature smoke ok\n'
