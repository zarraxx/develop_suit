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

host_triple_for_arch() {
  case "$1" in
    x86_64)
      echo "x86_64-unknown-linux-gnu"
      ;;
    aarch64)
      echo "aarch64-unknown-linux-gnu"
      ;;
    riscv64)
      echo "riscv64-unknown-linux-gnu"
      ;;
    loongarch64)
      echo "loongarch64-unknown-linux-gnu"
      ;;
    *)
      echo "error: unsupported arch: $1" >&2
      exit 1
      ;;
  esac
}

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
BUILD_TRIPLE="$("${SOURCE_ROOT}/config.guess")"
HOST_TRIPLE="$(host_triple_for_arch "$ARCH")"

echo "==> Configuring binutils ${BINUTILS_VERSION} build=${BUILD_TRIPLE} host=${HOST_TRIPLE} target=${TARGET_TRIPLE}" >&2
(
  cd "$BUILD_ROOT"
  CC="/opt/llvm-${LLVM_VERSION}/bin/${HOST_TRIPLE}-clang-gcc" \
  CXX="/opt/llvm-${LLVM_VERSION}/bin/${HOST_TRIPLE}-clang-g++" \
  AR="/opt/llvm-${LLVM_VERSION}/bin/${HOST_TRIPLE}-ar" \
  RANLIB="/opt/llvm-${LLVM_VERSION}/bin/${HOST_TRIPLE}-ranlib" \
  CC_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang" \
  CXX_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang++" \
  AR_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  RANLIB_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  CONFIG_SHELL="/usr/bin/bash" \
  SHELL="/usr/bin/bash" \
  GREP="/bin/grep" \
  EGREP="/bin/grep -E" \
  FGREP="/bin/grep -F" \
  ac_cv_path_GREP="/bin/grep" \
  ac_cv_path_EGREP="/bin/grep -E" \
  ac_cv_path_FGREP="/bin/grep -F" \
  "${SOURCE_ROOT}/configure" \
    --build="$BUILD_TRIPLE" \
    --host="$HOST_TRIPLE" \
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
make -C "$BUILD_ROOT" \
  SHELL="/usr/bin/bash" \
  CC_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang" \
  CXX_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang++" \
  AR_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  RANLIB_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  -j "$JOBS" \
  all-binutils all-gas all-ld
make -C "$BUILD_ROOT" \
  SHELL="/usr/bin/bash" \
  CC_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang" \
  CXX_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang++" \
  AR_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  RANLIB_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  install-binutils install-gas install-ld
