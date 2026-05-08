#!/usr/bin/env bash

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

render_template() {
  local template_path="$1"
  local output_path="$2"
  local content=""
  local key=""
  local value=""
  local assignment=""

  shift 2
  [[ -f "$template_path" ]] || die "template not found: ${template_path}"

  content="$(<"$template_path")"
  for assignment in "$@"; do
    key="${assignment%%=*}"
    value="${assignment#*=}"
    content="${content//"@${key}@"/$value}"
  done

  printf '%s\n' "$content" >"$output_path"
}

make_host_writable() {
  local path="$1"

  [[ -d "$path" ]] || return 0
  chmod -R a+rwX "$path" 2>/dev/null || true
  if command -v podman >/dev/null 2>&1; then
    podman unshare chmod -R a+rwX "$path" 2>/dev/null || true
  fi
}

resolve_target() {
  local input="$1"
  local description="${2:-target}"

  case "$input" in
    x86_64|amd64|x64|x86|x86_64-unknown-linux-gnu)
      ARCH="x86_64"
      TARGET_TRIPLE="x86_64-unknown-linux-gnu"
      TARGET_KIND="linux"
      PACKAGE_TRIPLE="x86_64-unknown-linux-gnu"
      ;;
    aarch64|arm64|aarch64-unknown-linux-gnu)
      ARCH="aarch64"
      TARGET_TRIPLE="aarch64-unknown-linux-gnu"
      TARGET_KIND="linux"
      PACKAGE_TRIPLE="aarch64-unknown-linux-gnu"
      ;;
    riscv64|riscv64gc|riscv64-unknown-linux-gnu)
      ARCH="riscv64"
      TARGET_TRIPLE="riscv64-unknown-linux-gnu"
      TARGET_KIND="linux"
      PACKAGE_TRIPLE="riscv64-unknown-linux-gnu"
      ;;
    loongarch64|loong64|loongarch64-unknown-linux-gnu)
      ARCH="loongarch64"
      TARGET_TRIPLE="loongarch64-unknown-linux-gnu"
      TARGET_KIND="linux"
      PACKAGE_TRIPLE="loongarch64-unknown-linux-gnu"
      ;;
    mingw64|windows|win64|x86_64-w64-windows-gnu)
      ARCH="x86_64"
      TARGET_TRIPLE="x86_64-w64-windows-gnu"
      TARGET_KIND="mingw"
      PACKAGE_TRIPLE="x86_64-w64-windows-gnu"
      ;;
    *)
      die "unsupported ${description}: $input"
      ;;
  esac

  SDK_PACKAGE_TRIPLE="$PACKAGE_TRIPLE"
}
