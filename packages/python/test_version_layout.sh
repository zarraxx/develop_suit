#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_HELPER="${ROOT_DIR}/mount_root/python_version.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$VERSION_HELPER" ]] || fail "missing Python version helper: ${VERSION_HELPER}"
source "$VERSION_HELPER"

assert_version_layout() {
  local version="$1"
  local expected_major_minor="$2"
  local expected_abi="$3"
  local actual_major_minor=""
  local actual_abi=""

  actual_major_minor="$(python_major_minor_version "$version")"
  actual_abi="$(python_abi_version "$version")"

  [[ "$actual_major_minor" == "$expected_major_minor" ]] \
    || fail "${version}: expected major.minor ${expected_major_minor}, got ${actual_major_minor}"
  [[ "$actual_abi" == "$expected_abi" ]] \
    || fail "${version}: expected ABI ${expected_abi}, got ${actual_abi}"
}

assert_version_layout "3.11.16" "3.11" "311"
assert_version_layout "3.13.15" "3.13" "313"
assert_version_layout "3.14.5" "3.14" "314"

[[ "$(python_package_version_for_target "x86_64" "3.13.15" "3.13.11")" == "3.13.15" ]] \
  || fail "Linux target must use the requested Python version"
[[ "$(python_package_version_for_target "mingw64" "3.13.15" "3.13.11")" == "3.13.11" ]] \
  || fail "MinGW target must use the requested MinGW Python version"
[[ "$(python_package_version_for_target "mingw64" "3.11.16" "3.11.10")" == "3.11.10" ]] \
  || fail "MinGW target must support an older requested MinGW Python version"
[[ "$(python_package_version_for_target "mingw64" "3.14.5" "")" == "3.14.5" ]] \
  || fail "MinGW target must fall back to the requested Python version"

echo "Python version layout tests passed"
