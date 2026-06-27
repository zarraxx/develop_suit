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
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/v8-mingw64-archive.XXXXXX")"
  tar -xf "${ARCHIVE}" -C "${TEST_ROOT}"
  PACKAGE_DIR="$(find "${TEST_ROOT}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | sed -n '1p')"
fi

[[ -n "${PACKAGE_DIR}" ]] || { echo "--package-dir or --archive is required" >&2; exit 1; }
[[ -d "${PACKAGE_DIR}" ]] || { echo "package directory not found: ${PACKAGE_DIR}" >&2; exit 1; }
PACKAGE_DIR="$(cd "${PACKAGE_DIR}" && pwd)"

[[ -f "${PACKAGE_DIR}/include/v8.h" ]] || { echo "missing header: ${PACKAGE_DIR}/include/v8.h" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/include/libplatform/libplatform.h" ]] || { echo "missing header: ${PACKAGE_DIR}/include/libplatform/libplatform.h" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/bin/d8.exe" ]] || { echo "missing d8 shell: ${PACKAGE_DIR}/bin/d8.exe" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/bin/libc++.dll" ]] || { echo "missing MinGW C++ runtime: ${PACKAGE_DIR}/bin/libc++.dll" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/bin/libunwind.dll" ]] || { echo "missing MinGW unwind runtime: ${PACKAGE_DIR}/bin/libunwind.dll" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/lib/pkgconfig/v8.pc" ]] || { echo "missing pkg-config metadata" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/lib/cmake/V8/V8Config.cmake" ]] || { echo "missing CMake metadata" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/lib/libc++.dll.a" ]] || { echo "missing MinGW C++ import library: ${PACKAGE_DIR}/lib/libc++.dll.a" >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/lib/libunwind.dll.a" ]] || { echo "missing MinGW unwind import library: ${PACKAGE_DIR}/lib/libunwind.dll.a" >&2; exit 1; }

if ! find "${PACKAGE_DIR}/lib" -maxdepth 1 -name 'libv8*.dll.a' | grep -q .; then
  echo "missing V8 import libraries" >&2
  exit 1
fi
if ! find "${PACKAGE_DIR}/lib" -maxdepth 1 -name '*.a' ! -name '*.dll.a' | grep -q .; then
  :
else
  echo "unexpected static archives in MinGW package" >&2
  find "${PACKAGE_DIR}/lib" -maxdepth 1 -name '*.a' ! -name '*.dll.a' -print >&2
  exit 1
fi
if ! find "${PACKAGE_DIR}/lib" -maxdepth 1 -name 'libv8*.dll' | grep -q .; then
  echo "missing V8 shared libraries" >&2
  exit 1
fi

export PATH="${PACKAGE_DIR}/bin:${PACKAGE_DIR}/lib:${PATH}"

if command -v file >/dev/null 2>&1; then
  file "${PACKAGE_DIR}/bin/d8.exe"
fi
if command -v ldd >/dev/null 2>&1; then
  ldd "${PACKAGE_DIR}/bin/d8.exe" || true
fi

"${PACKAGE_DIR}/bin/d8.exe" -e "print(version())"
"${PACKAGE_DIR}/bin/d8.exe" -e "if (6 * 7 !== 42) throw new Error('bad arithmetic');"
"${PACKAGE_DIR}/bin/d8.exe" -e "const xs=[1,2,3,4]; if (xs.reduce((a,b)=>a+b,0)!==10) throw new Error('bad reduce');"

echo "V8 MinGW64 package test passed: ${PACKAGE_DIR}"
