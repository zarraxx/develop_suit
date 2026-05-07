#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_ARCHIVE="${LLVM_ARCHIVE:-/work/cache/llvm-project-${LLVM_VERSION}.src.tar.xz}"
LIBLTO_SRC="${SRC_ROOT}/llvm-project-${LLVM_VERSION}.src"
LIBLTO_BUILD="${BUILD_ROOT}/build/liblto"
LIBLTO_TARGETS="${LIBLTO_TARGETS:-X86;AArch64;ARM}"
LIBLTO_DEP_INCLUDE="${BUILD_ROOT}/build/liblto-dep-include"

[[ -f "$LLVM_ARCHIVE" ]] || die "missing LLVM source archive: ${LLVM_ARCHIVE}"
[[ -f "${DEPS_USR}/lib/libz.so" ]] || die "missing stage_python zlib: ${DEPS_USR}/lib/libz.so"
[[ -f "${DEPS_USR}/include/zlib.h" ]] || die "missing stage_python zlib header: ${DEPS_USR}/include/zlib.h"
[[ -f "${DEPS_USR}/include/zconf.h" ]] || die "missing stage_python zlib header: ${DEPS_USR}/include/zconf.h"

mkdir -p "$LIBLTO_BUILD" "${LIBLTO_DEP_INCLUDE}/zlib"
ln -sf "${DEPS_USR}/include/zlib.h" "${LIBLTO_DEP_INCLUDE}/zlib/zlib.h"
ln -sf "${DEPS_USR}/include/zconf.h" "${LIBLTO_DEP_INCLUDE}/zlib/zconf.h"

if [[ ! -d "${LIBLTO_SRC}/llvm" ]]; then
  echo "-- extracting LLVM source: ${LLVM_ARCHIVE}"
  tar -xf "$LLVM_ARCHIVE" -C "$SRC_ROOT"
fi

[[ -d "${LIBLTO_SRC}/llvm" ]] || die "missing extracted LLVM source: ${LIBLTO_SRC}/llvm"

echo "-- building host libLTO"
echo "-- LLVM version: ${LLVM_VERSION}"
echo "-- libLTO target backends: ${LIBLTO_TARGETS}"

LIBLTO_LINK_FLAGS="-L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

cmake -S "${LIBLTO_SRC}/llvm" -B "$LIBLTO_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$OUT_DIR" \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_SYSROOT="$SYSROOT" \
  -DCMAKE_FIND_ROOT_PATH="${SYSROOT};${DEPS_USR}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  -DCMAKE_EXE_LINKER_FLAGS="$LIBLTO_LINK_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$LIBLTO_LINK_FLAGS" \
  -DCMAKE_AR="$AR" \
  -DCMAKE_RANLIB="$RANLIB" \
  -DCMAKE_STRIP="$STRIP" \
  -DCMAKE_NM="$NM" \
  -DCMAKE_OBJCOPY="$OBJCOPY" \
  -DPython3_EXECUTABLE="$Python3_EXECUTABLE" \
  -DLLVM_TABLEGEN="${LLVM_ROOT}/bin/llvm-tblgen" \
  -DLLVM_TARGETS_TO_BUILD="$LIBLTO_TARGETS" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_ENABLE_ZLIB=FORCE_ON \
  -DZLIB_ROOT="$DEPS_USR" \
  -DZLIB_INCLUDE_DIR="${LIBLTO_DEP_INCLUDE}/zlib" \
  -DZLIB_LIBRARY="${DEPS_USR}/lib/libz.so" \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_FFI=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_BENCHMARKS=OFF

cmake --build "$LIBLTO_BUILD" --target LTO -j "$JOBS"
cmake --install "$LIBLTO_BUILD" --component LTO

file "${OUT_DIR}/lib/libLTO.so" "${OUT_DIR}/include/llvm-c/lto.h" || true
echo "-- libLTO build ok: ${OUT_DIR}"
