#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

TARGET_TRIPLE="${TARGET_TRIPLE:-x86_64-w64-windows-gnu}"
JOBS="${JOBS:-4}"
DEPS_ROOT="${DEPS_ROOT:-/work/llvm_dependencies}"
LLVM_SDK_ROOT="${LLVM_SDK_ROOT:-/work/llvmsdk}"
OUT_DIR="${OUT_DIR:-/opt/osxcross-mingw64}"
CUSTOM_MODULES="${CUSTOM_MODULES:-liblto xar libtapi cctools}"

export LLVM_ROOT="/opt/llvm-18.1.8"
export DEPS_USR="$DEPS_ROOT"
export BUILD_ROOT="/work/build/osxcross-mingw64"
export SRC_ROOT="${BUILD_ROOT}/src"
export BUILD_TOOLS="${BUILD_ROOT}/tools"
export PATCH_DIR="/work/mingw64_mount_root/patch"
export MODULE_DIR="/work/mingw64_mount_root"
export TEMPLATE_DIR="/work/mingw64_mount_root/templates"

export PATH="/opt/cmake4/bin:${BUILD_TOOLS}:${LLVM_ROOT}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PKG_CONFIG_LIBDIR="${DEPS_USR}/lib/pkgconfig:${DEPS_USR}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="/"
export Python3_EXECUTABLE="/usr/bin/python3"

export CC="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc"
export CXX="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++"
export AR="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar"
export RANLIB="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib"
export STRIP="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip"
export NM="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm"
export OBJCOPY="${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy"
export WINDRES="${LLVM_ROOT}/bin/llvm-rc"

require_command patch
require_command make
require_command cmake
require_command ninja

[[ -x "$CC" ]] || die "missing target clang: ${CC}"
[[ -x "$CXX" ]] || die "missing target clang++: ${CXX}"
[[ -d "$DEPS_USR" ]] || die "missing MinGW dependency prefix: ${DEPS_USR}"
[[ -d "$LLVM_SDK_ROOT" ]] || die "missing MinGW LLVM SDK root: ${LLVM_SDK_ROOT}"
[[ -f "${DEPS_USR}/lib/libz.dll.a" ]] || die "missing zlib import library"
[[ -f "${DEPS_USR}/lib/libxml2.dll.a" ]] || die "missing libxml2 import library"
[[ -f "${LLVM_SDK_ROOT}/lib/libLTO.dll.a" ]] || die "missing libLTO import library"
[[ -f "${LLVM_SDK_ROOT}/bin/libLTO.dll" ]] || die "missing libLTO DLL"

mkdir -p "$SRC_ROOT" "$BUILD_TOOLS" "$OUT_DIR"

echo "-- osxcross MinGW container"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- deps: ${DEPS_USR}"
echo "-- llvmsdk: ${LLVM_SDK_ROOT}"
echo "-- modules: ${CUSTOM_MODULES}"

for module in $CUSTOM_MODULES; do
  case "$module" in
    liblto|lto)
      /bin/bash "${MODULE_DIR}/custom_liblto.sh"
      ;;
    xar)
      /bin/bash "${MODULE_DIR}/custom_xar.sh"
      ;;
    libtapi|tapi)
      /bin/bash "${MODULE_DIR}/custom_libtapi.sh"
      ;;
    cctools)
      /bin/bash "${MODULE_DIR}/custom_cctools.sh"
      ;;
    *)
      die "unknown MinGW osxcross module: ${module}"
      ;;
  esac
done

echo "-- osxcross MinGW modules ok: ${OUT_DIR}"
