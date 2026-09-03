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

python_package_version_for_target() {
  local target="$1"
  local python_version="$2"
  local mingw_python_version="$3"

  if [[ "$target" == "mingw64" && -n "$mingw_python_version" ]]; then
    printf '%s\n' "$mingw_python_version"
    return 0
  fi

  printf '%s\n' "$python_version"
}

python_mingw_patch_for_version() {
  local major_minor=""

  major_minor="$(python_major_minor_version "$1")" || return 1
  printf 'cpython-mingw-%s-cross-host-platform.patch\n' "$major_minor"
}
