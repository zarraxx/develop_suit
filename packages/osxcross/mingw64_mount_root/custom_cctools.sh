#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

CCTOOLS_SRC="${SRC_ROOT}/cctools-port"
CCTOOLS_BUILD="${BUILD_ROOT}/build/cctools"
OSXCROSS_TARGET="${OSXCROSS_TARGET:-darwin22.4}"
OSXCROSS_TARGET_ARCH="${OSXCROSS_TARGET_ARCH:-arm64}"
OSXCROSS_TARGET_TRIPLE="${OSXCROSS_TARGET_ARCH}-apple-${OSXCROSS_TARGET}"

[[ -d "/work/upstream/cctools-port/cctools" ]] || die "missing upstream cctools-port source"
[[ -f "${OUT_DIR}/include/tapi/tapi.h" ]] || die "missing libtapi headers"
[[ -f "${OUT_DIR}/lib/libtapi.dll.a" ]] || die "missing libtapi import library"
[[ -f "${OUT_DIR}/include/llvm-c/lto.h" ]] || die "missing libLTO header"
[[ -f "${OUT_DIR}/lib/libLTO.dll.a" ]] || die "missing libLTO import library"
[[ -x "${OUT_DIR}/bin/llvm-config" ]] || die "missing llvm-config wrapper"
[[ -f "${OUT_DIR}/include/xar/xar.h" ]] || die "missing xar headers"
[[ -f "${OUT_DIR}/lib/libxar.dll.a" ]] || die "missing xar import library"

rm -rf "$CCTOOLS_SRC" "$CCTOOLS_BUILD"
mkdir -p "$CCTOOLS_BUILD"
cp -a /work/upstream/cctools-port "$CCTOOLS_SRC"
(
  cd "$CCTOOLS_SRC"
  patch -p1 < "${PATCH_DIR}/cctools-llvm18-disassembler-callback.patch"
)

echo "-- building MinGW cctools"
echo "-- osxcross target: ${OSXCROSS_TARGET_TRIPLE}"

TARGET_CPPFLAGS="-I${DEPS_USR}/include -I${DEPS_USR}/include/libxml2"
TARGET_CFLAGS="-O2 -w ${TARGET_CPPFLAGS}"
TARGET_CXXFLAGS="-O2 -w ${TARGET_CPPFLAGS}"
TARGET_LDFLAGS="-L${OUT_DIR}/lib -L${DEPS_USR}/lib"
TARGET_LIBS="-lxml2 -lz -lws2_32 -lbcrypt"

cd "$CCTOOLS_BUILD"
CC="$CC" \
CXX="$CXX" \
AR="$AR" \
RANLIB="$RANLIB" \
STRIP="$STRIP" \
NM="$NM" \
CFLAGS="$TARGET_CFLAGS" \
CXXFLAGS="$TARGET_CXXFLAGS" \
CPPFLAGS="$TARGET_CPPFLAGS" \
LDFLAGS="$TARGET_LDFLAGS" \
LD="${LLVM_ROOT}/bin/ld.lld" \
LIBS="$TARGET_LIBS" \
"${CCTOOLS_SRC}/cctools/configure" \
  --prefix="$OUT_DIR" \
  --build=x86_64-unknown-linux-gnu \
  --host="$TARGET_TRIPLE" \
  --target="$OSXCROSS_TARGET_TRIPLE" \
  --with-llvm-config="${OUT_DIR}/bin/llvm-config" \
  --with-libtapi="$OUT_DIR" \
  --with-libxar="$OUT_DIR"

make -j"$JOBS"
make install -j"$JOBS"
find "${OUT_DIR}/lib" -maxdepth 1 -name '*.la' -delete

file "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-ld.exe" "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-ar.exe" || true
echo "-- MinGW cctools build ok: ${OUT_DIR}"
