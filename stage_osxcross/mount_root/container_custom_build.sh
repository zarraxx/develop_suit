#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ARCH="${ARCH:-}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
JOBS="${JOBS:-4}"
DEPS_DIR="${DEPS_DIR:-/work/deps/${ARCH}}"
OUT_DIR="${OUT_DIR:-/opt/osxcross}"
CUSTOM_MODULES="${CUSTOM_MODULES:-xar libtapi liblto cctools}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"

export LLVM_ROOT="/opt/llvm-18.1.8"
export SYSROOT="/opt/sysroot/${TARGET_TRIPLE}"
export DEPS_USR="${DEPS_DIR}/usr"
export BUILD_ROOT="/work/build/${ARCH}/osxcross-custom"
export SRC_ROOT="${BUILD_ROOT}/src"
export BUILD_TOOLS="${BUILD_ROOT}/tools"
export PATCH_DIR="/work/mount_root/patch"
export MODULE_DIR="/work/mount_root"

export PATH="/opt/cmake4/bin:${BUILD_TOOLS}:${LLVM_ROOT}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PKG_CONFIG_LIBDIR="${DEPS_USR}/lib/pkgconfig:${DEPS_USR}/lib64/pkgconfig:${DEPS_USR}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="/"
export Python3_EXECUTABLE="/usr/bin/python3"

export CC="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc"
export CXX="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++"
export AR="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar"
export RANLIB="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib"
export STRIP="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip"
export NM="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm"
export OBJCOPY="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy"

require_command patch
require_command make
require_command cmake
require_command ninja

[[ -x "$CC" ]] || die "missing target clang: ${TARGET_TRIPLE}-clang-gcc"
[[ -x "$CXX" ]] || die "missing target clang++: ${TARGET_TRIPLE}-clang-g++"
[[ -x "$AR" ]] || die "missing target ar: ${TARGET_TRIPLE}-ar"
[[ -x "$RANLIB" ]] || die "missing target ranlib: ${TARGET_TRIPLE}-ranlib"
[[ -x "$STRIP" ]] || die "missing target strip: ${TARGET_TRIPLE}-strip"
[[ -x "$NM" ]] || die "missing target nm: ${TARGET_TRIPLE}-nm"
[[ -x "$OBJCOPY" ]] || die "missing target objcopy: ${TARGET_TRIPLE}-objcopy"
[[ -d "$SYSROOT" ]] || die "missing target sysroot: ${SYSROOT}"
[[ -d "$DEPS_USR" ]] || die "missing host deps /usr: ${DEPS_USR}"

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_ROOT" "$BUILD_TOOLS" "$OUT_DIR"
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "-- stage_osxcross custom container"
echo "-- arch: ${ARCH}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- host deps usr: ${DEPS_USR}"
echo "-- build python: ${Python3_EXECUTABLE}"
echo "-- modules: ${CUSTOM_MODULES}"

for module in $CUSTOM_MODULES; do
  case "$module" in
    xar)
      /bin/bash "${MODULE_DIR}/custom_xar.sh"
      ;;
    libtapi|tapi)
      /bin/bash "${MODULE_DIR}/custom_libtapi.sh"
      ;;
    liblto|lto)
      /bin/bash "${MODULE_DIR}/custom_liblto.sh"
      ;;
    cctools)
      /bin/bash "${MODULE_DIR}/custom_cctools.sh"
      ;;
    *)
      die "unknown custom module: ${module}"
      ;;
  esac
done

echo "-- stage_osxcross custom modules ok: ${OUT_DIR}"
