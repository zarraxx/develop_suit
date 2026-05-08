#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_TRIPLE="x86_64-w64-windows-gnu"
LLVM_VERSION="18.1.8"
BINUTILS_VERSION="2.46.0"
BINUTILS_ARCHIVE_NAME="binutils-${BINUTILS_VERSION}.tar.xz"
BINUTILS_ALIAS_PATCH="${SCRIPT_DIR}/patches/binutils-${BINUTILS_VERSION}-windows-gnu.patch"

JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build"
PREFIX=""

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/container_native_binutils.sh --prefix=/work/out/llvm18.1.8 [options]

Options:
  --prefix=<path>     Final native Windows install prefix
  --jobs=<n>          Parallel build jobs
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  Build dir (default: /work/build)
  -h, --help          Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix=*)
      PREFIX="${1#*=}"
      ;;
    --prefix)
      shift
      [[ $# -gt 0 ]] || die "--prefix requires a value"
      PREFIX="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --cache-dir=*)
      CACHE_DIR="${1#*=}"
      ;;
    --cache-dir)
      shift
      [[ $# -gt 0 ]] || die "--cache-dir requires a value"
      CACHE_DIR="$1"
      ;;
    --build-dir=*)
      BUILD_DIR="${1#*=}"
      ;;
    --build-dir)
      shift
      [[ $# -gt 0 ]] || die "--build-dir requires a value"
      BUILD_DIR="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$PREFIX" ]] || die "--prefix is required"

for command_name in make patch tar; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done

[[ -f "${CACHE_DIR}/${BINUTILS_ARCHIVE_NAME}" ]] || die "missing binutils archive: ${CACHE_DIR}/${BINUTILS_ARCHIVE_NAME}"
[[ -f "$BINUTILS_ALIAS_PATCH" ]] || die "missing binutils alias patch: ${BINUTILS_ALIAS_PATCH}"

SOURCE_ROOT="${BUILD_DIR}/binutils-native-source"
BUILD_ROOT="${BUILD_DIR}/binutils-native-build"

if [[ ! -f "${SOURCE_ROOT}/configure" ]]; then
  rm -rf "$SOURCE_ROOT"
  mkdir -p "$SOURCE_ROOT"
  tar -xf "${CACHE_DIR}/${BINUTILS_ARCHIVE_NAME}" -C "$SOURCE_ROOT" --strip-components=1
fi

[[ -f "${SOURCE_ROOT}/bfd/config.bfd" ]] || die "invalid binutils source tree: ${SOURCE_ROOT}"

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

echo "==> Configuring native Windows binutils ${BINUTILS_VERSION} build=${BUILD_TRIPLE} host=${TARGET_TRIPLE} target=${TARGET_TRIPLE}" >&2
(
  cd "$BUILD_ROOT"
  CC="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-gcc" \
  CXX="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-g++" \
  AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  DLLTOOL="/opt/llvm-${LLVM_VERSION}/bin/llvm-dlltool" \
  WINDRES="/opt/llvm-${LLVM_VERSION}/bin/llvm-windres" \
  CC_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang" \
  CXX_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/clang++" \
  AR_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  RANLIB_FOR_BUILD="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  CONFIG_SHELL="/usr/bin/bash" \
  SHELL="/usr/bin/bash" \
  GREP="/bin/grep" \
  EGREP="/bin/grep -E" \
  FGREP="/bin/grep -F" \
  ac_cv_exeext=".exe" \
  ac_cv_path_GREP="/bin/grep" \
  ac_cv_path_EGREP="/bin/grep -E" \
  ac_cv_path_FGREP="/bin/grep -F" \
  "${SOURCE_ROOT}/configure" \
    --build="$BUILD_TRIPLE" \
    --host="$TARGET_TRIPLE" \
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

echo "==> Building native Windows binutils ${BINUTILS_VERSION}" >&2
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
