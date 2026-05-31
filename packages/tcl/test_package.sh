#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/var.sh"
source "${SHELL_TOOLS_DIR}/tools.sh"

usage() {
  cat <<'EOF'
Usage:
  ./packages/tcl/test_package.sh --target=<target> --package-dir=<dir>
  ./packages/tcl/test_package.sh --target=<target> --archive=<tar.xz>

Options:
  --target=<target>       Tcl package target
  --arch=<target>         Alias for --target
  --package-dir=<dir>     Extracted Tcl package prefix
  --archive=<tar.xz>      Tcl package archive to extract and test
  -h, --help              Show this help
EOF
}

TARGET=""
PACKAGE_DIR=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    --package-dir=*) PACKAGE_DIR="${1#*=}" ;;
    --package-dir)
      shift
      [[ $# -gt 0 ]] || die "--package-dir requires a value"
      PACKAGE_DIR="$1"
      ;;
    --archive=*) ARCHIVE="${1#*=}" ;;
    --archive)
      shift
      [[ $# -gt 0 ]] || die "--archive requires a value"
      ARCHIVE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "Tcl package test target"

if [[ -n "$PACKAGE_DIR" && -n "$ARCHIVE" ]]; then
  die "--package-dir and --archive are mutually exclusive"
fi

if [[ -n "$ARCHIVE" ]]; then
  [[ -f "$ARCHIVE" ]] || die "archive not found: ${ARCHIVE}"
  TEST_ROOT="${ROOT_DIR}/build/test/${PACKAGE_TRIPLE}"
  rm -rf "$TEST_ROOT"
  mkdir -p "$TEST_ROOT"
  tar -xf "$ARCHIVE" -C "$TEST_ROOT"
  PACKAGE_DIR="$(
    find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -print \
      | sort \
      | head -n 1
  )"
fi

[[ -n "$PACKAGE_DIR" ]] || die "--package-dir or --archive is required"
[[ -d "$PACKAGE_DIR" ]] || die "package directory not found: ${PACKAGE_DIR}"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "missing file: ${path}"
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || die "missing executable: ${path}"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "missing directory: ${path}"
}

check_file_target() {
  local path="$1"
  local expected="$2"

  command -v file >/dev/null 2>&1 || return 0
  file "$path"
  file "$path" | grep -qi "$expected" || die "unexpected file target for ${path}; expected ${expected}"
}

require_file "${PACKAGE_DIR}/README.tcl"
require_dir "${PACKAGE_DIR}/bin"
require_dir "${PACKAGE_DIR}/include"
require_dir "${PACKAGE_DIR}/lib"
require_file "${PACKAGE_DIR}/include/tcl.h"
require_file "${PACKAGE_DIR}/lib/tclConfig.sh"

case "$TARGET_KIND" in
  linux)
    require_executable "${PACKAGE_DIR}/bin/tclsh8.6"
    require_file "${PACKAGE_DIR}/lib/libtcl8.6.so"

    if [[ "$ARCH" == "x86_64" ]]; then
      echo "Running Tcl x86_64 smoke test"
      LD_LIBRARY_PATH="${PACKAGE_DIR}/lib:${LD_LIBRARY_PATH:-}" \
        "${PACKAGE_DIR}/bin/tclsh8.6" <<'TCL'
if {[info patchlevel] eq ""} {
    error "missing Tcl patchlevel"
}
package require Tcl
puts "tcl package smoke ok [info patchlevel]"
TCL
      check_file_target "${PACKAGE_DIR}/bin/tclsh8.6.bin" "x86-64"
    elif [[ "$ARCH" == "aarch64" ]]; then
      check_file_target "${PACKAGE_DIR}/bin/tclsh8.6.bin" "aarch64"
    elif [[ "$ARCH" == "riscv64" ]]; then
      check_file_target "${PACKAGE_DIR}/bin/tclsh8.6.bin" "riscv"
    elif [[ "$ARCH" == "loongarch64" ]]; then
      check_file_target "${PACKAGE_DIR}/bin/tclsh8.6.bin" "loongarch"
    fi
    ;;
  mingw)
    require_file "${PACKAGE_DIR}/bin/tclsh86.exe"
    require_file "${PACKAGE_DIR}/bin/tcl86.dll"
    require_file "${PACKAGE_DIR}/lib/libtcl86.dll.a"
    check_file_target "${PACKAGE_DIR}/bin/tclsh86.exe" "PE32+"
    ;;
  *)
    die "unsupported target kind: ${TARGET_KIND}"
    ;;
esac

echo "Tcl package test passed: ${PACKAGE_TRIPLE}"
