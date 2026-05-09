#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

CCTOOLS_SRC="${SRC_ROOT}/cctools-port"
CCTOOLS_BUILD="${BUILD_ROOT}/build/cctools"
MACOS_SDK_VERSION="${MACOS_SDK_VERSION:-13.3}"
OSXCROSS_TARGET="${OSXCROSS_TARGET:-darwin22.4}"
OSXCROSS_ARCHS="${OSXCROSS_ARCHS:-arm64 arm64e x86_64 x86_64h}"
OSXCROSS_TARGET_ARCH="${OSXCROSS_TARGET_ARCH:-${OSXCROSS_ARCHS%% *}}"
OSXCROSS_TARGET_TRIPLE="${OSXCROSS_TARGET_ARCH}-apple-${OSXCROSS_TARGET}"

[[ -d "/work/upstream/cctools-port/cctools" ]] || die "missing upstream cctools-port source"
[[ -f "${OUT_DIR}/include/tapi/tapi.h" ]] || die "missing libtapi headers: ${OUT_DIR}/include/tapi/tapi.h"
[[ -f "${OUT_DIR}/lib/libtapi.so" ]] || die "missing libtapi library: ${OUT_DIR}/lib/libtapi.so"
[[ -f "${OUT_DIR}/include/llvm-c/lto.h" ]] || die "missing libLTO header: ${OUT_DIR}/include/llvm-c/lto.h"
[[ -f "${OUT_DIR}/lib/libLTO.so" ]] || die "missing libLTO library: ${OUT_DIR}/lib/libLTO.so"
[[ -x "${OUT_DIR}/bin/llvm-config" ]] || die "missing llvm-config wrapper: ${OUT_DIR}/bin/llvm-config"
[[ -f "${OUT_DIR}/include/xar/xar.h" ]] || die "missing xar headers: ${OUT_DIR}/include/xar/xar.h"
[[ -f "${OUT_DIR}/lib/libxar.a" || -f "${OUT_DIR}/lib/libxar.so" ]] || die "missing xar library under ${OUT_DIR}/lib"

rm -rf "$CCTOOLS_SRC" "$CCTOOLS_BUILD"
mkdir -p "$CCTOOLS_BUILD"
cp -a /work/upstream/cctools-port "$CCTOOLS_SRC"
(
  cd "$CCTOOLS_SRC"
  patch -p1 < "${PATCH_DIR}/cctools-llvm18-disassembler-callback.patch"
)

echo "-- building cctools"
echo "-- macOS SDK version hint: ${MACOS_SDK_VERSION}"
echo "-- osxcross target: ${OSXCROSS_TARGET_TRIPLE}"
echo "-- osxcross arch symlinks: ${OSXCROSS_ARCHS}"

CCTOOLS_HOST_ARCH_FLAGS=""
case "$TARGET_TRIPLE" in
  loongarch64-unknown-linux-gnu|riscv64-unknown-linux-gnu)
    CCTOOLS_HOST_ARCH_FLAGS="-D__x86_64__"
    ;;
esac

TARGET_CPPFLAGS="-I${DEPS_USR}/include -I${DEPS_USR}/include/libxml2 ${CCTOOLS_HOST_ARCH_FLAGS}"
TARGET_CFLAGS="--sysroot=${SYSROOT} -O2 -w ${TARGET_CPPFLAGS}"
TARGET_CXXFLAGS="--sysroot=${SYSROOT} -O2 -w ${TARGET_CPPFLAGS}"
TARGET_LDFLAGS="--sysroot=${SYSROOT} -L${OUT_DIR}/lib -L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${OUT_DIR}/lib -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

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
LIBS="-lxml2 -lz -lm" \
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
find "${OUT_DIR}/lib" -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -delete

(
  cd "${OUT_DIR}/bin"
  for tool in "${OSXCROSS_TARGET_TRIPLE}"-*; do
    [[ -e "$tool" ]] || continue
    for arch in $OSXCROSS_ARCHS; do
      [[ "$arch" != "$OSXCROSS_TARGET_ARCH" ]] || continue
      ln -sf "$tool" "${tool/#${OSXCROSS_TARGET_ARCH}-apple-${OSXCROSS_TARGET}/${arch}-apple-${OSXCROSS_TARGET}}"
    done
  done
  if [[ -e "x86_64-apple-${OSXCROSS_TARGET}-lipo" ]]; then
    ln -sf "x86_64-apple-${OSXCROSS_TARGET}-lipo" lipo
  elif [[ -e "${OSXCROSS_TARGET_TRIPLE}-lipo" ]]; then
    ln -sf "${OSXCROSS_TARGET_TRIPLE}-lipo" lipo
  fi
)

file "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-ld" "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-ar" || true
echo "-- cctools build ok: ${OUT_DIR}"
