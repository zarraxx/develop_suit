#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./stages/stage1/prepare.sh

What it does:
  - installs base host build dependencies for stage1
  - installs host glibc development packages
  - installs qemu user-mode emulation + binfmt support
  - handles Ubuntu 24.04 and 26.04 package differences
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "[stage1/prepare] $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command apt-get

if [[ ! -r /etc/os-release ]]; then
  die "cannot detect host distribution: /etc/os-release is missing"
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  die "this prepare script currently supports Ubuntu hosts only"
fi

SUDO=()
if [[ "${EUID}" -ne 0 ]]; then
  require_command sudo
  SUDO=(sudo)
fi

BASE_PACKAGES=(
  autoconf
  automake
  binutils
  build-essential
  bzip2
  ca-certificates
  cmake
  curl
  file
  gawk
  git
  libtool
  make
  m4
  ninja-build
  patch
  perl
  pkg-config
  python3
  sed
  tar
  xz-utils
)

HOST_GLIBC_PACKAGES=(
  libc6
  libc6-dev
  locales
)

QEMU_PACKAGES=()
case "${VERSION_ID:-}" in
  "24.04")
    QEMU_PACKAGES=(
      binfmt-support
      qemu-user-static
    )
    ;;
  "26.04")
    QEMU_PACKAGES=(
      binfmt-support
      qemu-user
      qemu-user-binfmt
    )
    ;;
  *)
    die "unsupported Ubuntu version: ${VERSION_ID:-unknown}; expected 24.04 or 26.04"
    ;;
esac

info "Detected Ubuntu ${VERSION_ID:-unknown} (${VERSION_CODENAME:-unknown})"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  info "Running inside GitHub Actions"
fi

info "Updating apt package index"
"${SUDO[@]}" apt-get update

info "Installing base build dependencies"
"${SUDO[@]}" apt-get install -y "${BASE_PACKAGES[@]}"

info "Installing host glibc packages"
"${SUDO[@]}" apt-get install -y "${HOST_GLIBC_PACKAGES[@]}"

info "Installing qemu + binfmt packages: ${QEMU_PACKAGES[*]}"
"${SUDO[@]}" apt-get install -y "${QEMU_PACKAGES[@]}"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files systemd-binfmt.service >/dev/null 2>&1; then
    info "Restarting systemd-binfmt"
    "${SUDO[@]}" systemctl restart systemd-binfmt || true
  fi
fi

if [[ -e /usr/lib/binfmt.d/qemu-aarch64.conf ]]; then
  info "Found qemu aarch64 binfmt config: /usr/lib/binfmt.d/qemu-aarch64.conf"
fi

if [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
  info "qemu-aarch64 binfmt entry is active"
else
  info "qemu-aarch64 binfmt entry is not active yet"
  info "You can inspect it with: ls /usr/lib/binfmt.d/qemu-aarch64.conf && systemctl status systemd-binfmt"
fi

info "Done"
