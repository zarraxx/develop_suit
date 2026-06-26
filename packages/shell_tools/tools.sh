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

patch_linux_elf_rpaths() {
  local prefix="$1"
  local target_kind="${2:-${TARGET_KIND:-linux}}"
  local file_path=""
  local file_dir=""
  local relative_lib_dir=""
  local subdir=""
  local rest=""
  local depth=0
  local i=0
  local rpath=""
  local needed_before=""
  local needed_after=""
  local backup_path=""

  [[ "$target_kind" == "linux" ]] || return 0
  [[ -d "$prefix" ]] || return 0

  require_command patchelf

  while IFS= read -r -d '' file_path; do
    needed_before="$(patchelf --print-needed "$file_path" 2>/dev/null || true)"
    [[ -n "$needed_before" ]] || continue

    file_dir="$(dirname "$file_path")"
    case "$file_dir" in
      "$prefix")
        relative_lib_dir="lib"
        ;;
      "${prefix}/lib")
        relative_lib_dir="."
        ;;
      "${prefix}/lib/"*)
        subdir="${file_dir#"${prefix}/lib/"}"
        IFS='/' read -r -a rpath_parts <<<"$subdir"
        depth="${#rpath_parts[@]}"
        relative_lib_dir=""
        for ((i = 0; i < depth; i++)); do
          relative_lib_dir+="${relative_lib_dir:+/}.."
        done
        ;;
      "${prefix}/"*)
        subdir="${file_dir#"${prefix}/"}"
        IFS='/' read -r -a rpath_parts <<<"$subdir"
        depth="${#rpath_parts[@]}"
        relative_lib_dir=""
        for ((i = 0; i < depth; i++)); do
          relative_lib_dir+="${relative_lib_dir:+/}.."
        done
        relative_lib_dir+="/lib"
        ;;
      *)
        continue
        ;;
    esac

    if [[ "$relative_lib_dir" == "." ]]; then
      rpath="\$ORIGIN"
    else
      rpath="\$ORIGIN/${relative_lib_dir}"
    fi

    case "$file_path" in
      "${prefix}/lib/"*)
        if [[ "$rpath" != "\$ORIGIN" ]]; then
          rpath="\$ORIGIN:${rpath}"
        fi
        ;;
    esac

    backup_path="$(mktemp "${file_path}.rpath-backup.XXXXXX")"
    cp -p "$file_path" "$backup_path"
    if ! patchelf --set-rpath "$rpath" "$file_path"; then
      mv -f "$backup_path" "$file_path"
      echo "warning: patchelf failed for ${file_path}; rpath left unchanged" >&2
      continue
    fi

    needed_after="$(patchelf --print-needed "$file_path" 2>/dev/null || true)"
    if [[ "$needed_after" != "$needed_before" ]]; then
      mv -f "$backup_path" "$file_path"
      echo "warning: patchelf changed DT_NEEDED for ${file_path}; rpath left unchanged" >&2
      continue
    fi
    rm -f "$backup_path"
  done < <(
    find "${prefix}/bin" "${prefix}/lib" \
      -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) \
      -print0 2>/dev/null
  )
}

make_host_writable() {
  local path="$1"

  [[ -d "$path" ]] || return 0
  chmod -R a+rwX "$path" 2>/dev/null || true
  if command -v podman >/dev/null 2>&1; then
    podman unshare chmod -R a+rwX "$path" 2>/dev/null || true
  fi
}

normalize_package_permissions() {
  local path="$1"

  [[ -d "$path" ]] || return 0

  find "$path" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$path" -type f -perm /111 -exec chmod 755 {} + 2>/dev/null || true
  find "$path" -type f ! -perm /111 -exec chmod 644 {} + 2>/dev/null || true

  if command -v podman >/dev/null 2>&1; then
    podman unshare find "$path" -type d -exec chmod 755 {} + 2>/dev/null || true
    podman unshare find "$path" -type f -perm /111 -exec chmod 755 {} + 2>/dev/null || true
    podman unshare find "$path" -type f ! -perm /111 -exec chmod 644 {} + 2>/dev/null || true
  fi
}

materialize_symlinks() {
  local root="$1"
  local link_path=""
  local target_path=""
  local tmp_path=""

  [[ -d "$root" ]] || return 0
  require_command readlink

  while IFS= read -r link_path; do
    [[ -L "$link_path" ]] || continue
    target_path="$(readlink -f "$link_path" 2>/dev/null || true)"
    [[ -n "$target_path" && -e "$target_path" ]] || die "broken symlink in package tree: ${link_path}"

    tmp_path="${link_path}.materialize.$$"
    rm -rf "$tmp_path"
    cp -a "$target_path" "$tmp_path"
    rm -f "$link_path"
    mv "$tmp_path" "$link_path"
  done < <(find "$root" -type l -print | LC_ALL=C sort)
}

write_noop_ldconfig_wrapper() {
  local tools_dir="$1"
  local wrapper_path="${tools_dir}/ldconfig"

  mkdir -p "$tools_dir"
  cat >"$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --help|-h)
    echo "ldconfig wrapper: disabled for staged cross-package prefixes"
    exit 0
    ;;
  --version|-V)
    echo "ldconfig wrapper"
    exit 0
    ;;
esac

exit 0
EOF
  chmod +x "$wrapper_path"
}

target_qemu_user_binary_names() {
  local arch="${1:-${ARCH:-}}"

  case "$arch" in
    aarch64)
      printf '%s\n' "qemu-aarch64-static" "qemu-aarch64"
      ;;
    riscv64)
      printf '%s\n' "qemu-riscv64-static" "qemu-riscv64"
      ;;
    loongarch64)
      printf '%s\n' "qemu-loongarch64-static" "qemu-loongarch64"
      ;;
    *)
      return 1
      ;;
  esac
}

find_host_qemu_user_binary() {
  local arch="${1:-${ARCH:-}}"
  local qemu_name=""
  local qemu_path=""

  while IFS= read -r qemu_name; do
    qemu_path="$(command -v "$qemu_name" 2>/dev/null || true)"
    if [[ -n "$qemu_path" ]]; then
      printf '%s\n' "$qemu_path"
      return 0
    fi
  done < <(target_qemu_user_binary_names "$arch")

  return 1
}

resolve_container_runtime() {
  local requested_runtime="${1:-}"

  if [[ -n "$requested_runtime" ]]; then
    require_command "$requested_runtime"
    printf '%s\n' "$requested_runtime"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    printf '%s\n' "podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker"
    return 0
  fi

  die "no supported container runtime found; install podman or docker"
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
