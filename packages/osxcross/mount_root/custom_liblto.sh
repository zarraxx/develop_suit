#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

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
render_template "${TEMPLATE_DIR}/llvm-config.in" "${OUT_DIR}/bin/llvm-config" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "LLVM_TARGETS=all" \
  "LLVM_EXPERIMENTAL_TARGETS="
[[ ! -d "${LLVM_SDK_ROOT}/include/llvm" ]] || cp -a "${LLVM_SDK_ROOT}/include/llvm" "${OUT_DIR}/include/"
[[ ! -d "${LLVM_SDK_ROOT}/include/llvm-c" ]] || cp -a "${LLVM_SDK_ROOT}/include/llvm-c" "${OUT_DIR}/include/"
[[ ! -d "${LLVM_SDK_ROOT}/lib/cmake" ]] || cp -a "${LLVM_SDK_ROOT}/lib/cmake" "${OUT_DIR}/lib/"
if [[ "$DEPS_USR" != "$LLVM_SDK_ROOT" ]]; then
  find "${DEPS_USR}/lib" -maxdepth 1 \
    \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -a {} "${OUT_DIR}/lib/" \;
fi
find "${LLVM_SDK_ROOT}/lib" -maxdepth 1 \
  \( -name '*.so' -o -name '*.so.*' \) \
  -exec cp -a {} "${OUT_DIR}/lib/" \;

chmod +x "${OUT_DIR}/bin/llvm-config"
file "${OUT_DIR}/lib/libLLVM.so" "${OUT_DIR}/lib/libLTO.so" "${OUT_DIR}/include/llvm-c/lto.h" "${OUT_DIR}/bin/llvm-config" || true
echo "-- LLVM SDK libLTO install ok: ${OUT_DIR}"
