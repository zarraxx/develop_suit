#!/usr/bin/env bash

python_major_minor_version() {
  local version="$1"

  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)(\.|$) ]]; then
    echo "invalid Python version: ${version}" >&2
    return 1
  fi

  printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

python_abi_version() {
  local major_minor=""

  major_minor="$(python_major_minor_version "$1")" || return 1
  printf '%s\n' "${major_minor//./}"
}
