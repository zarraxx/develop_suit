#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./packages/v8/test_package_mingw64.sh --target=mingw64 --archive=<tar.xz>
  ./packages/v8/test_package_mingw64.sh --target=mingw64 --package-dir=<dir>
EOF
}

TARGET=""
PACKAGE_DIR=""
ARCHIVE=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  mingw64|windows|x86_64-w64-windows-gnu) ;;
  *)
    echo "test_package_mingw64.sh only supports mingw64/windows targets" >&2
    exit 1
    ;;
esac

if [[ -n "${PACKAGE_DIR}" && -n "${ARCHIVE}" ]]; then
  echo "--package-dir and --archive are mutually exclusive" >&2
  exit 1
fi

if [[ -n "${ARCHIVE}" ]]; then
  [[ -f "${ARCHIVE}" ]] || { echo "archive not found: ${ARCHIVE}" >&2; exit 1; }
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/v8-mingw-archive.XXXXXX")"
  tar -xf "${ARCHIVE}" -C "${TEST_ROOT}"
  PACKAGE_DIR="$(find "${TEST_ROOT}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | sed -n '1p')"
fi

[[ -n "${PACKAGE_DIR}" ]] || { echo "--package-dir or --archive is required" >&2; exit 1; }
[[ -d "${PACKAGE_DIR}" ]] || { echo "package directory not found: ${PACKAGE_DIR}" >&2; exit 1; }
PACKAGE_DIR="$(cd "${PACKAGE_DIR}" && pwd)"

[[ -f "${PACKAGE_DIR}/include/v8.h" ]] || { echo "missing header: ${PACKAGE_DIR}/include/v8.h" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/lib/libv8_snapshot.a" ]] || { echo "missing static library: ${PACKAGE_DIR}/lib/libv8_snapshot.a" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/lib/pkgconfig/v8.pc" ]] || { echo "missing pkg-config metadata" >&2; exit 1; }
[[ -x "${PACKAGE_DIR}/bin/d8.exe" ]] || { echo "missing d8.exe shell binary" >&2; exit 1; }

if find "${PACKAGE_DIR}/lib" -maxdepth 1 \( -name 'libv8*.dll' -o -name 'v8.dll' \) | grep -q .; then
  echo "unexpected shared V8 DLLs found in package" >&2
  find "${PACKAGE_DIR}/lib" -maxdepth 1 \( -name 'libv8*.dll' -o -name 'v8.dll' \) >&2
  exit 1
fi

if find "${PACKAGE_DIR}/bin" -maxdepth 1 \( -name 'libv8*.dll' -o -name 'v8.dll' \) | grep -q .; then
  echo "unexpected shared V8 DLLs found in bin/" >&2
  find "${PACKAGE_DIR}/bin" -maxdepth 1 \( -name 'libv8*.dll' -o -name 'v8.dll' \) >&2
  exit 1
fi

export PATH="${PACKAGE_DIR}/bin:${PACKAGE_DIR}/lib:${PATH}"

"${PACKAGE_DIR}/bin/d8.exe" -e "print(version())"
"${PACKAGE_DIR}/bin/d8.exe" -e "if (6 * 7 !== 42) throw new Error('bad arithmetic');"
"${PACKAGE_DIR}/bin/d8.exe" -e "const xs=[1,2,3,4]; if (xs.reduce((a,b)=>a+b,0)!==10) throw new Error('bad reduce');"

echo "V8 MinGW package test passed: ${PACKAGE_DIR}"
