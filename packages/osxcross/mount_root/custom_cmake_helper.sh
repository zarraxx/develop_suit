#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

OSXCROSS_TOOLS="/work/upstream/osxcross/tools"
OSXCROSS_TARGET="${OSXCROSS_TARGET:-darwin22.4}"
OSXCROSS_ARCHS="${OSXCROSS_ARCHS:-arm64 arm64e x86_64 x86_64h}"

[[ -f "${OSXCROSS_TOOLS}/toolchain.cmake" ]] || die "missing upstream osxcross toolchain.cmake"
[[ -f "${OSXCROSS_TOOLS}/osxcross-cmake" ]] || die "missing upstream osxcross-cmake"

echo "-- installing osxcross CMake helper"

mkdir -p "${OUT_DIR}/bin"
install -m 0644 "${OSXCROSS_TOOLS}/toolchain.cmake" "${OUT_DIR}/toolchain.cmake"
install -m 0755 "${OSXCROSS_TOOLS}/osxcross-cmake" "${OUT_DIR}/bin/osxcross-cmake"

(
  cd "${OUT_DIR}/bin"
  for arch in $OSXCROSS_ARCHS; do
    ln -sf osxcross-cmake "${arch}-apple-${OSXCROSS_TARGET}-cmake"
  done
  case " ${OSXCROSS_ARCHS} " in
    *" arm64 "*)
      ln -sf osxcross-cmake "aarch64-apple-${OSXCROSS_TARGET}-cmake"
      ;;
  esac
)

echo "-- osxcross CMake helper install ok: ${OUT_DIR}"
