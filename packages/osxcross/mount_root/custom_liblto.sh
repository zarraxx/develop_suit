#!/usr/bin/env bash

set -euo pipefail

LLVM_VERSION="${LLVM_VERSION:-18.1.8}"

[[ -n "${LLVM_SDK_ROOT:-}" ]] || die "LLVM_SDK_ROOT is required for libLTO install"

echo "-- installing libLLVM/libLTO from LLVM SDK"
echo "-- LLVM SDK root: ${LLVM_SDK_ROOT}"

[[ -x "${LLVM_SDK_ROOT}/bin/llvm-config" ]] || die "missing LLVM SDK llvm-config: ${LLVM_SDK_ROOT}/bin/llvm-config"
[[ -f "${LLVM_SDK_ROOT}/include/llvm-c/lto.h" ]] || die "missing LLVM SDK libLTO header: ${LLVM_SDK_ROOT}/include/llvm-c/lto.h"
[[ -f "${LLVM_SDK_ROOT}/lib/libLTO.so" ]] || die "missing LLVM SDK libLTO library: ${LLVM_SDK_ROOT}/lib/libLTO.so"
[[ -f "${LLVM_SDK_ROOT}/lib/libLLVM.so" || -f "${LLVM_SDK_ROOT}/lib/libLLVM-${LLVM_VERSION%%.*}.so" ]] \
  || die "missing LLVM SDK libLLVM library under: ${LLVM_SDK_ROOT}/lib"

mkdir -p "${OUT_DIR}/bin" "${OUT_DIR}/include" "${OUT_DIR}/lib"
cp -a "${LLVM_SDK_ROOT}/bin/llvm-config" "${OUT_DIR}/bin/"
[[ ! -d "${LLVM_SDK_ROOT}/include/llvm" ]] || cp -a "${LLVM_SDK_ROOT}/include/llvm" "${OUT_DIR}/include/"
[[ ! -d "${LLVM_SDK_ROOT}/include/llvm-c" ]] || cp -a "${LLVM_SDK_ROOT}/include/llvm-c" "${OUT_DIR}/include/"
[[ ! -d "${LLVM_SDK_ROOT}/lib/cmake" ]] || cp -a "${LLVM_SDK_ROOT}/lib/cmake" "${OUT_DIR}/lib/"
find "${LLVM_SDK_ROOT}/lib" -maxdepth 1 \
  \( \
    -name 'libLLVM*.so' \
    -o -name 'libLLVM*.so.*' \
    -o -name 'libLTO.so' \
    -o -name 'libLTO.so.*' \
    -o -name 'libz.so' \
    -o -name 'libz.so.*' \
    -o -name 'libzstd.so' \
    -o -name 'libzstd.so.*' \
    -o -name 'libxml2.so' \
    -o -name 'libxml2.so.*' \
    -o -name 'libiconv.so' \
    -o -name 'libiconv.so.*' \
    -o -name 'libcharset.so' \
    -o -name 'libcharset.so.*' \
    -o -name 'libffi.so' \
    -o -name 'libffi.so.*' \
    -o -name 'libtinfo*.so' \
    -o -name 'libtinfo*.so.*' \
    -o -name 'libncurses*.so' \
    -o -name 'libncurses*.so.*' \
    -o -name 'libreadline.so' \
    -o -name 'libreadline.so.*' \
    -o -name 'libhistory.so' \
    -o -name 'libhistory.so.*' \
  \) -exec cp -a {} "${OUT_DIR}/lib/" \;

chmod +x "${OUT_DIR}/bin/llvm-config"
file "${OUT_DIR}/lib/libLLVM.so" "${OUT_DIR}/lib/libLTO.so" "${OUT_DIR}/include/llvm-c/lto.h" "${OUT_DIR}/bin/llvm-config" || true
echo "-- LLVM SDK libLTO install ok: ${OUT_DIR}"
