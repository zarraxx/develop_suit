#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

OSXCROSS_TOOLS="/work/upstream/osxcross/tools"

[[ -f "${OSXCROSS_TOOLS}/osxcross-macports" ]] || die "missing upstream osxcross-macports"

echo "-- installing osxcross MacPorts helper"

mkdir -p "${OUT_DIR}/bin"
install -m 0755 "${OSXCROSS_TOOLS}/osxcross-macports" "${OUT_DIR}/bin/osxcross-macports"

(
  cd "${OUT_DIR}/bin"
  ln -sf osxcross-macports osxcross-mp
  ln -sf osxcross-macports omp
)

echo "-- osxcross MacPorts helper install ok: ${OUT_DIR}"
