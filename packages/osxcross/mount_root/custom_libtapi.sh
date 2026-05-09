#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

TAPI_SRC="${SRC_ROOT}/apple-libtapi"
TAPI_NATIVE_BUILD="${BUILD_ROOT}/build/tapi-native-tblgen"
TAPI_BUILD="${BUILD_ROOT}/build/tapi"
TAPI_DEP_INCLUDE="${BUILD_ROOT}/build/tapi-dep-include"

[[ -d "/work/upstream/apple-libtapi/src/llvm" ]] || die "missing upstream apple-libtapi source"
[[ -f "${DEPS_USR}/lib/libz.so" ]] || die "missing dependency zlib: ${DEPS_USR}/lib/libz.so"
[[ -f "${DEPS_USR}/lib/libxml2.so" ]] || die "missing dependency libxml2: ${DEPS_USR}/lib/libxml2.so"
[[ -f "${DEPS_USR}/include/zlib.h" ]] || die "missing dependency zlib header: ${DEPS_USR}/include/zlib.h"
[[ -f "${DEPS_USR}/include/zconf.h" ]] || die "missing dependency zlib header: ${DEPS_USR}/include/zconf.h"
[[ -d "${DEPS_USR}/include/libxml2" ]] || die "missing dependency libxml2 headers"

rm -rf "$TAPI_SRC" "$TAPI_NATIVE_BUILD" "$TAPI_BUILD"
mkdir -p "$TAPI_NATIVE_BUILD" "$TAPI_BUILD" "${TAPI_DEP_INCLUDE}/zlib"
ln -sf "${DEPS_USR}/include/zlib.h" "${TAPI_DEP_INCLUDE}/zlib/zlib.h"
ln -sf "${DEPS_USR}/include/zconf.h" "${TAPI_DEP_INCLUDE}/zlib/zconf.h"
cp -a /work/upstream/apple-libtapi "$TAPI_SRC"

echo "-- building tapi native tablegen"

cmake -S "${TAPI_SRC}/src/llvm" -B "$TAPI_NATIVE_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${LLVM_ROOT}/bin/clang" \
  -DCMAKE_CXX_COMPILER="${LLVM_ROOT}/bin/clang++" \
  -DCMAKE_AR="${LLVM_ROOT}/bin/llvm-ar" \
  -DCMAKE_RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
  -DCMAKE_NM="${LLVM_ROOT}/bin/llvm-nm" \
  -DCMAKE_OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy" \
  -DCMAKE_STRIP="${LLVM_ROOT}/bin/llvm-strip" \
  -DPython3_EXECUTABLE="$Python3_EXECUTABLE" \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_TARGET_ARCH=X86 \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
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

cmake --build "$TAPI_NATIVE_BUILD" --target llvm-tblgen clang-tblgen -j "$JOBS"

echo "-- building libtapi"

TAPI_LINK_FLAGS="-L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
TAPI_CXX_FLAGS="-I${TAPI_SRC}/src/clang/include -I${TAPI_BUILD}/tools/clang/include"

cmake -S "${TAPI_SRC}/src/llvm" -B "$TAPI_BUILD" -G Ninja \
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
  -DCMAKE_CXX_FLAGS="$TAPI_CXX_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$TAPI_LINK_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$TAPI_LINK_FLAGS" \
  -DCMAKE_AR="$AR" \
  -DCMAKE_RANLIB="$RANLIB" \
  -DCMAKE_STRIP="$STRIP" \
  -DCMAKE_NM="$NM" \
  -DCMAKE_OBJCOPY="$OBJCOPY" \
  -DPython3_EXECUTABLE="$Python3_EXECUTABLE" \
  -DLLVM_TABLEGEN="${TAPI_NATIVE_BUILD}/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="${TAPI_NATIVE_BUILD}/bin/clang-tblgen" \
  -DLLVM_ENABLE_PROJECTS="tapi;clang" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DTAPI_INCLUDE_DOCS=OFF \
  -DTAPI_INCLUDE_TESTS=OFF \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_TARGET_ARCH=X86 \
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DLLVM_ENABLE_ZLIB=FORCE_ON \
  -DZLIB_ROOT="$DEPS_USR" \
  -DZLIB_INCLUDE_DIR="${TAPI_DEP_INCLUDE}/zlib" \
  -DZLIB_LIBRARY="${DEPS_USR}/lib/libz.so" \
  -DLLVM_ENABLE_LIBXML2=FORCE_ON \
  -DLibXml2_ROOT="$DEPS_USR" \
  -DLIBXML2_INCLUDE_DIR="${DEPS_USR}/include/libxml2" \
  -DLIBXML2_LIBRARY="${DEPS_USR}/lib/libxml2.so" \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_FFI=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_BENCHMARKS=OFF \
  -DTAPI_REPOSITORY_STRING=1300.6.5 \
  -DTAPI_FULL_VERSION=1300.6.5

cmake --build "$TAPI_BUILD" --target clangBasic libtapi -j "$JOBS"
cmake --build "$TAPI_BUILD" --target install-libtapi install-tapi-headers -j "$JOBS"

file "${OUT_DIR}/lib/libtapi.so" "${OUT_DIR}/lib/libtapi.so.12git" || true
echo "-- libtapi build ok: ${OUT_DIR}"
