#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLANG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${CLANG_ROOT}/mount_root/libcxx_overlay.sh"

die() {
  echo "test failure: $*" >&2
  exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

sdk_prefix="${test_root}/sdk"
runtime_root="${test_root}/runtimes"
runtime_prefix="${runtime_root}/libcxx-23.1.0-x86_64-w64-windows-gnu"

mkdir -p \
  "${sdk_prefix}/include/c++/v1" \
  "${runtime_prefix}/include/c++/v1" \
  "${runtime_prefix}/lib/x86_64-w64-windows-gnu"

printf '%s\n' old-cctype >"${sdk_prefix}/include/c++/v1/cctype"
printf '%s\n' stale-libcxx-wrapper >"${sdk_prefix}/include/c++/v1/ctype.h"
printf '%s\n' current-cctype >"${runtime_prefix}/include/c++/v1/cctype"
printf '%s\n' current-runtime >"${runtime_prefix}/lib/x86_64-w64-windows-gnu/libc++.dll.a"

overlay_libcxx_runtime_packages "$sdk_prefix" "$runtime_root"

[[ "$(<"${sdk_prefix}/include/c++/v1/cctype")" == current-cctype ]] \
  || die "current libc++ headers did not replace the staged headers"
[[ ! -e "${sdk_prefix}/include/c++/v1/ctype.h" ]] \
  || die "stale libc++ C compatibility header survived the overlay"
[[ "$(<"${sdk_prefix}/lib/x86_64-w64-windows-gnu/libc++.dll.a")" == current-runtime ]] \
  || die "libc++ runtime libraries were not overlaid"

echo "libcxx overlay layout test passed"
