#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_TRIPLE="x86_64-w64-windows-gnu"
LLVM_VERSION="18.1.8"
BINUTILS_VERSION="2.46.0"
BINUTILS_ARCHIVE_NAME="binutils-${BINUTILS_VERSION}.tar.xz"
BINUTILS_ALIAS_PATCH="${SCRIPT_DIR}/patches/binutils-${BINUTILS_VERSION}-windows-gnu.patch"

ARCH=""
JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build"
PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch=*)
      ARCH="${1#*=}"
      ;;
    --arch)
      shift
      [[ $# -gt 0 ]] || { echo "error: --arch requires a value" >&2; exit 1; }
      ARCH="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || { echo "error: --jobs requires a value" >&2; exit 1; }
      JOBS="$1"
      ;;
    --cache-dir=*)
      CACHE_DIR="${1#*=}"
      ;;
    --cache-dir)
      shift
      [[ $# -gt 0 ]] || { echo "error: --cache-dir requires a value" >&2; exit 1; }
      CACHE_DIR="$1"
      ;;
    --build-dir=*)
      BUILD_DIR="${1#*=}"
      ;;
    --build-dir)
      shift
      [[ $# -gt 0 ]] || { echo "error: --build-dir requires a value" >&2; exit 1; }
      BUILD_DIR="$1"
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      ;;
    --prefix)
      shift
      [[ $# -gt 0 ]] || { echo "error: --prefix requires a value" >&2; exit 1; }
      PREFIX="$1"
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  /work/mount_root/build_binutils.sh --arch=x86_64 --prefix=/work/out/x86_64/opt/x86_64-w64-windows-gnu [options]

Options:
  --arch=<arch>       Host arch for produced Linux binutils
  --prefix=<path>     Final install prefix
  --jobs=<n>          Parallel build jobs
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  Build dir (default: /work/build)
  -h, --help          Show this help
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ -n "$ARCH" ]] || { echo "error: --arch is required" >&2; exit 1; }
[[ -n "$PREFIX" ]] || { echo "error: --prefix is required" >&2; exit 1; }

for command_name in make patch tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: required command not found: ${command_name}" >&2
    exit 1
  }
done

[[ -f "${CACHE_DIR}/${BINUTILS_ARCHIVE_NAME}" ]] || {
  echo "error: missing binutils archive: ${CACHE_DIR}/${BINUTILS_ARCHIVE_NAME}" >&2
  exit 1
}
[[ -f "$BINUTILS_ALIAS_PATCH" ]] || {
  echo "error: missing binutils alias patch: ${BINUTILS_ALIAS_PATCH}" >&2
  exit 1
}

SOURCE_ROOT="${BUILD_DIR}/${ARCH}/binutils-source"
BUILD_ROOT="${BUILD_DIR}/${ARCH}/binutils-build"

if [[ ! -f "${SOURCE_ROOT}/configure" ]]; then
  rm -rf "$SOURCE_ROOT"
  mkdir -p "$SOURCE_ROOT"
  tar -xf "${CACHE_DIR}/${BINUTILS_ARCHIVE_NAME}" -C "$SOURCE_ROOT" --strip-components=1
fi

[[ -f "${SOURCE_ROOT}/bfd/config.bfd" ]] || {
  echo "error: invalid binutils source tree: ${SOURCE_ROOT}" >&2
  exit 1
}

if [[ ! -f "${SOURCE_ROOT}/.stage-mingw64-windows-gnu-alias" ]]; then
  (
    cd "$SOURCE_ROOT"
    patch -p1 -i "$BINUTILS_ALIAS_PATCH"
  )
  "${SOURCE_ROOT}/config.sub" "$TARGET_TRIPLE" >/dev/null
  touch "${SOURCE_ROOT}/.stage-mingw64-windows-gnu-alias"
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
HOST_TRIPLET="$("${SOURCE_ROOT}/config.guess")"

echo "==> Configuring binutils ${BINUTILS_VERSION} for ${TARGET_TRIPLE}" >&2
(
  cd "$BUILD_ROOT"
  CC="/opt/llvm-${LLVM_VERSION}/bin/clang" \
  CXX="/opt/llvm-${LLVM_VERSION}/bin/clang++" \
  AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  "${SOURCE_ROOT}/configure" \
    --build="$HOST_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --target="$TARGET_TRIPLE" \
    --prefix="$PREFIX" \
    --with-sysroot="${PREFIX}/sysroot" \
    --disable-nls \
    --disable-werror \
    --disable-gdb \
    --disable-gdbserver \
    --disable-gprofng \
    --disable-libdecnumber \
    --disable-readline \
    --disable-sim
)

echo "==> Building binutils ${BINUTILS_VERSION} for ${TARGET_TRIPLE}" >&2
make -C "$BUILD_ROOT" -j "$JOBS" all-binutils all-gas all-ld
make -C "$BUILD_ROOT" install-binutils install-gas install-ld
