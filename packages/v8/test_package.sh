#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./packages/v8/test_package.sh --target=<target> --archive=<tar.xz>
  ./packages/v8/test_package.sh --target=<target> --package-dir=<dir>
EOF
}

TARGET=""
PACKAGE_DIR=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      shift
      [[ $# -gt 0 ]] || { echo "--target requires a value" >&2; exit 1; }
      TARGET="$1"
      ;;
    --package-dir=*) PACKAGE_DIR="${1#*=}" ;;
    --package-dir)
      shift
      [[ $# -gt 0 ]] || { echo "--package-dir requires a value" >&2; exit 1; }
      PACKAGE_DIR="$1"
      ;;
    --archive=*) ARCHIVE="${1#*=}" ;;
    --archive)
      shift
      [[ $# -gt 0 ]] || { echo "--archive requires a value" >&2; exit 1; }
      ARCHIVE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

case "${TARGET}" in
  x86_64|x86_64-unknown-linux-gnu|aarch64|aarch64-unknown-linux-gnu|arm64|riscv64|riscv64-unknown-linux-gnu|loongarch64|loongarch64-unknown-linux-gnu) ;;
  *)
    echo "test_package.sh only supports Linux V8 targets" >&2
    exit 1
    ;;
esac

case "${TARGET}" in
  x86_64|x86_64-unknown-linux-gnu) TARGET_TRIPLE="x86_64-unknown-linux-gnu" ;;
  aarch64|aarch64-unknown-linux-gnu|arm64) TARGET_TRIPLE="aarch64-unknown-linux-gnu" ;;
  riscv64|riscv64-unknown-linux-gnu) TARGET_TRIPLE="riscv64-unknown-linux-gnu" ;;
  loongarch64|loongarch64-unknown-linux-gnu) TARGET_TRIPLE="loongarch64-unknown-linux-gnu" ;;
esac

if [[ -n "${PACKAGE_DIR}" && -n "${ARCHIVE}" ]]; then
  echo "--package-dir and --archive are mutually exclusive" >&2
  exit 1
fi

if [[ -n "${ARCHIVE}" ]]; then
  [[ -f "${ARCHIVE}" ]] || { echo "archive not found: ${ARCHIVE}" >&2; exit 1; }
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/v8-archive.XXXXXX")"
  tar -xf "${ARCHIVE}" -C "${TEST_ROOT}"
  PACKAGE_DIR="$(find "${TEST_ROOT}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | sed -n '1p')"
fi

[[ -n "${PACKAGE_DIR}" ]] || { echo "--package-dir or --archive is required" >&2; exit 1; }
[[ -d "${PACKAGE_DIR}" ]] || { echo "package directory not found: ${PACKAGE_DIR}" >&2; exit 1; }
PACKAGE_DIR="$(cd "${PACKAGE_DIR}" && pwd)"

[[ -f "${PACKAGE_DIR}/include/v8.h" ]] || { echo "missing header: ${PACKAGE_DIR}/include/v8.h" >&2; exit 1; }
if ! find "${PACKAGE_DIR}/lib" -maxdepth 1 \( -name 'libv8*.so' -o -name 'libv8*.so.*' \) | grep -q .; then
  echo "missing V8 shared libraries" >&2
  exit 1
fi
[[ -f "${PACKAGE_DIR}/lib/pkgconfig/v8.pc" ]] || { echo "missing pkg-config metadata" >&2; exit 1; }
[[ -x "${PACKAGE_DIR}/bin/d8" ]] || { echo "missing d8 shell binary" >&2; exit 1; }

export PATH="${PACKAGE_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${PACKAGE_DIR}/lib:/opt/llvm-18.1.8/lib/${TARGET_TRIPLE}:/opt/llvm-18.1.8/lib/clang/18/lib/${TARGET_TRIPLE}:/opt/llvm-18.1.8/lib:/opt/llvm-18.1.8/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if command -v file >/dev/null 2>&1; then
  file "${PACKAGE_DIR}/bin/d8"
fi
if command -v readelf >/dev/null 2>&1; then
  readelf -h "${PACKAGE_DIR}/bin/d8" | sed -n '1,20p'
fi
if command -v ldd >/dev/null 2>&1; then
  ldd "${PACKAGE_DIR}/bin/d8" || true
fi

"${PACKAGE_DIR}/bin/d8" -e "print(version())"
"${PACKAGE_DIR}/bin/d8" -e "if (6 * 7 !== 42) throw new Error('bad arithmetic');"
"${PACKAGE_DIR}/bin/d8" -e "const xs=[1,2,3,4]; if (xs.reduce((a,b)=>a+b,0)!==10) throw new Error('bad reduce');"

echo "V8 package test passed: ${PACKAGE_DIR}"
