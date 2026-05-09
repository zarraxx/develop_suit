#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

LLVM_VERSION="${LLVM_VERSION:-18.1.8}"

[[ -d "${LLVM_SDK_ROOT:-}" ]] || die "LLVM_SDK_ROOT is required"

echo "-- installing MinGW libLLVM/libLTO from LLVM SDK"

mkdir -p "${OUT_DIR}/bin" "${OUT_DIR}/include" "${OUT_DIR}/lib"
render_template "${TEMPLATE_DIR}/llvm-config.in" "${OUT_DIR}/bin/llvm-config" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "LLVM_TARGETS=all"
chmod +x "${OUT_DIR}/bin/llvm-config"

[[ ! -d "${LLVM_SDK_ROOT}/include/llvm" ]] || cp -a "${LLVM_SDK_ROOT}/include/llvm" "${OUT_DIR}/include/"
[[ ! -d "${LLVM_SDK_ROOT}/include/llvm-c" ]] || cp -a "${LLVM_SDK_ROOT}/include/llvm-c" "${OUT_DIR}/include/"
[[ ! -d "${LLVM_SDK_ROOT}/lib/cmake" ]] || cp -a "${LLVM_SDK_ROOT}/lib/cmake" "${OUT_DIR}/lib/"

find "${DEPS_USR}/bin" -maxdepth 1 -name '*.dll' -exec cp -a {} "${OUT_DIR}/bin/" \;
find "${DEPS_USR}/lib" -maxdepth 1 -name '*.dll.a' -exec cp -a {} "${OUT_DIR}/lib/" \;
find "${LLVM_SDK_ROOT}/bin" -maxdepth 1 -name '*.dll' -exec cp -a {} "${OUT_DIR}/bin/" \;
find "${LLVM_SDK_ROOT}/lib" -maxdepth 1 -name '*.dll.a' -exec cp -a {} "${OUT_DIR}/lib/" \;

[[ -f "${OUT_DIR}/bin/libLTO.dll" ]] || die "missing installed libLTO.dll"
[[ -f "${OUT_DIR}/lib/libLTO.dll.a" ]] || die "missing installed libLTO.dll.a"
[[ -f "${OUT_DIR}/bin/libLLVM-18.dll" ]] || die "missing installed libLLVM-18.dll"
[[ -f "${OUT_DIR}/lib/libLLVM-18.dll.a" ]] || die "missing installed libLLVM-18.dll.a"
[[ -f "${OUT_DIR}/include/llvm-c/lto.h" ]] || die "missing installed lto.h"

file "${OUT_DIR}/bin/libLTO.dll" "${OUT_DIR}/bin/libLLVM-18.dll" || true
echo "-- MinGW libLTO install ok: ${OUT_DIR}"
