#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

LLVM_VERSION="18.1.8"
LLVM_RESOURCE_VERSION="18"
LLVM_SOURCE_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz"
SYSROOT_URL="https://github.com/zarraxx/package_builder/releases/download/sysroot-15.2.0/sysroot-15.2.0-linux.tar.xz"
BOOTSTRAP_X86_64_URL="https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-x86_64.tar.gz"
BOOTSTRAP_AARCH64_URL="https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-aarch64.tar.gz"
DEFAULT_INSTALL_PREFIX="/opt/llvm-${LLVM_VERSION}"
DEFAULT_SYSROOT_PREFIX="/opt/sysroot"

ALL_ARCHES=(
  x86_64
  aarch64
  riscv64
  loongarch64
)

ALL_TARGET_TRIPLES=(
  x86_64-unknown-linux-gnu
  aarch64-unknown-linux-gnu
  riscv64-unknown-linux-gnu
  loongarch64-unknown-linux-gnu
)

usage() {
  cat <<'EOF'
Usage:
  ./stage_llvm/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>                     Host arch for the produced clang:
                                    x86_64, aarch64, riscv64, loongarch64
  --clean                           Remove the per-arch build directory before building
  --jobs=<n>                        Parallel build jobs passed to CMake
  --verbose                         Enable verbose CMake build output
  --download-missing                Download missing source/bootstrap archives into cache/
  --build-dir=<path>                Override per-arch build directory
  --dist-dir=<path>                 Override final output directory
                                    (default: <repo>/dist/stage_llvm/<arch>)
  --input-rootfs-dir=<path>         Override input rootfs directory
                                    (default: <repo>/dist/stage_python/<arch>)
  --install-prefix=<path>           LLVM install prefix inside rootfs
                                    (default: /opt/llvm-18.1.8)
  --sysroot-prefix=<path>           Sysroot install prefix inside rootfs
                                    (default: /opt/sysroot)
  --sysroot-root=<path>             Directory containing <triple>/sysroot trees
  --sysroot-archive=<path>          Override sysroot archive path
  --llvm-source-dir=<path>          Use a pre-extracted llvm-project source tree
  --llvm-archive=<path>             Override llvm-project source archive path
  --bootstrap-clang-root=<path>     Use a pre-extracted bootstrap clang root
  --bootstrap-clang-archive=<path>  Override bootstrap clang archive path
  --cmake-arg=<arg>                 Extra argument for host LLVM configure (repeatable)
  --runtime-cmake-arg=<arg>         Extra argument for runtime configure (repeatable)
  -h, --help                        Show this help

Notes:
  - --arch describes the host architecture of the generated clang binary.
  - This script cross-builds the final clang binaries for --arch on the
    current machine, using a runnable bootstrap LLVM toolchain for the build host.
  - The produced toolchain contains one host clang plus 4 Linux target sysroots
    and runtime libraries for:
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      riscv64-unknown-linux-gnu
      loongarch64-unknown-linux-gnu
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

normalize_arch() {
  case "$1" in
    x86_64|amd64|x64|x86)
      echo "x86_64"
      ;;
    aarch64|arm64)
      echo "aarch64"
      ;;
    riscv64|riscv64gc)
      echo "riscv64"
      ;;
    loongarch64|loong64)
      echo "loongarch64"
      ;;
    *)
      die "unsupported arch: $1"
      ;;
  esac
}

target_triple_for_arch() {
  case "$1" in
    x86_64)
      echo "x86_64-unknown-linux-gnu"
      ;;
    aarch64)
      echo "aarch64-unknown-linux-gnu"
      ;;
    riscv64)
      echo "riscv64-unknown-linux-gnu"
      ;;
    loongarch64)
      echo "loongarch64-unknown-linux-gnu"
      ;;
    *)
      die "no target triple mapping for arch: $1"
      ;;
  esac
}

llvm_native_target_name_for_arch() {
  case "$1" in
    x86_64)
      echo "X86"
      ;;
    aarch64)
      echo "AArch64"
      ;;
    riscv64)
      echo "riscv64"
      ;;
    loongarch64)
      echo "LoongArch"
      ;;
    *)
      die "no LLVM native target mapping for arch: $1"
      ;;
  esac
}

default_bootstrap_url_for_arch() {
  case "$1" in
    x86_64)
      echo "${BOOTSTRAP_X86_64_URL}"
      ;;
    aarch64)
      echo "${BOOTSTRAP_AARCH64_URL}"
      ;;
    *)
      echo ""
      ;;
  esac
}

copy_tree_clean() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || die "source directory does not exist: $src"

  cmake -E rm -rf "$dst"
  cmake -E make_directory "$dst"
  cp -a "${src}/." "$dst/"
}

archive_stem() {
  local input_path="$1"
  local name
  name="$(basename "$input_path")"
  name="${name%.tar.gz}"
  name="${name%.tar.xz}"
  name="${name%.tar.bz2}"
  name="${name%.tgz}"
  name="${name%.txz}"
  name="${name%.tbz2}"
  echo "$name"
}

download_file_once() {
  local output_path="$1"
  local url="$2"
  local description="$3"

  if [[ -f "$output_path" ]]; then
    return
  fi

  [[ -n "$url" ]] || die "no download URL configured for ${description}"
  require_command curl

  local tmp_path="${output_path}.tmp"
  mkdir -p "$(dirname "$output_path")"

  log "Downloading ${description}: ${url}"
  curl -L --fail -o "$tmp_path" "$url"
  mv "$tmp_path" "$output_path"
}

ensure_default_archive() {
  local output_var="$1"
  local description="$2"
  local cache_dir="$3"
  local archive_name="$4"
  local archive_url="$5"

  local archive_path="${cache_dir}/${archive_name}"
  if [[ ! -f "$archive_path" ]]; then
    if [[ "$DOWNLOAD_MISSING" -ne 1 ]]; then
      die "missing ${description}: ${archive_path} (use --download-missing or pass an explicit path)"
    fi
    download_file_once "$archive_path" "$archive_url" "$description"
  fi

  printf -v "$output_var" '%s' "$archive_path"
}

extract_archive_once() {
  local archive_path="$1"
  local destination_dir="$2"
  local marker_relpath="$3"

  [[ -f "$archive_path" ]] || die "archive does not exist: $archive_path"

  local archive_hash
  archive_hash="$(sha256sum "$archive_path" | awk '{print $1}')"
  local stamp_path="${destination_dir}/.extract.sha256"

  if [[ -f "$stamp_path" && -e "${destination_dir}/${marker_relpath}" ]]; then
    local existing_hash
    existing_hash="$(tr -d '[:space:]' < "$stamp_path")"
    if [[ "$existing_hash" == "$archive_hash" ]]; then
      return
    fi
  fi

  log "Extracting $(basename "$archive_path")"
  cmake -E rm -rf "$destination_dir"
  cmake -E make_directory "$destination_dir"
  tar -xf "$archive_path" -C "$destination_dir"
  printf '%s\n' "$archive_hash" > "$stamp_path"
}

unwrap_single_subdir() {
  local root_dir="$1"
  local marker_relpath="$2"
  local current_dir="$root_dir"
  local depth=0

  while [[ ! -e "${current_dir}/${marker_relpath}" ]]; do
    (( depth <= 8 )) || die "could not find ${marker_relpath} under ${root_dir}"

    local subdirs=()
    local child
    for child in "${current_dir}"/*; do
      [[ -d "$child" ]] || continue
      subdirs+=("$child")
    done

    [[ ${#subdirs[@]} -eq 1 ]] || die "could not find ${marker_relpath} under ${root_dir}"
    current_dir="${subdirs[0]}"
    depth=$((depth + 1))
  done

  printf '%s\n' "$current_dir"
}

path_under_rootfs() {
  local rootfs_dir="$1"
  local install_path="$2"
  local trimmed="${install_path#/}"
  printf '%s/%s\n' "$rootfs_dir" "$trimmed"
}

resolve_llvm_source_dir() {
  if [[ -n "$LLVM_SOURCE_DIR" ]]; then
    [[ -f "${LLVM_SOURCE_DIR}/llvm/CMakeLists.txt" ]] || die "invalid llvm source tree: ${LLVM_SOURCE_DIR}"
    printf '%s\n' "$LLVM_SOURCE_DIR"
    return
  fi

  if [[ -z "$LLVM_ARCHIVE" ]]; then
    ensure_default_archive \
      LLVM_ARCHIVE \
      "llvm-project source archive" \
      "$CACHE_DIR" \
      "llvm-project-${LLVM_VERSION}.src.tar.xz" \
      "$LLVM_SOURCE_URL"
  fi

  local extract_dir="${BUILD_DIR}/source/llvm-project"
  extract_archive_once "$LLVM_ARCHIVE" "$extract_dir" "llvm-project-${LLVM_VERSION}.src"
  unwrap_single_subdir "$extract_dir" "llvm/CMakeLists.txt"
}

apply_llvm_source_patches() {
  local llvm_source_root="$1"
  local smallvector_header="${llvm_source_root}/llvm/include/llvm/ADT/SmallVector.h"
  local compiler_rt_cmakelists="${llvm_source_root}/compiler-rt/CMakeLists.txt"

  [[ -f "$smallvector_header" ]] || die "expected llvm SmallVector header not found: ${smallvector_header}"
  [[ -f "$compiler_rt_cmakelists" ]] || die "expected compiler-rt CMakeLists.txt not found: ${compiler_rt_cmakelists}"

  # GCC 15 no longer picks up uint32_t/uint64_t transitively for this header.
  # LLVM 18 still relies on that transitive include, which breaks the NATIVE
  # tblgen build used during cross-host LLVM builds.
  if ! grep -Fq '#include <cstdint>' "$smallvector_header"; then
    log "Patching llvm/ADT/SmallVector.h for explicit <cstdint> include"
    sed -i '/#include <cassert>/a #include <cstdint>' "$smallvector_header"
  fi

  if ! grep -Fq 'COMPILER_RT_EXTRA_CXX_CFLAGS' "$compiler_rt_cmakelists"; then
    log "Patching compiler-rt/CMakeLists.txt to support target libc++ header overlay flags"
    python3 - "$compiler_rt_cmakelists" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = "set(COMPILER_RT_COMMON_LINK_FLAGS ${SANITIZER_COMMON_LINK_FLAGS})\n"
replacement = needle + """
set(COMPILER_RT_EXTRA_CXX_CFLAGS "" CACHE STRING
  "Extra C++ flags appended when building compiler-rt C++ sources.")
if(NOT COMPILER_RT_EXTRA_CXX_CFLAGS STREQUAL "")
  separate_arguments(_COMPILER_RT_EXTRA_CXX_CFLAGS NATIVE_COMMAND "${COMPILER_RT_EXTRA_CXX_CFLAGS}")
  list(APPEND SANITIZER_COMMON_CFLAGS ${_COMPILER_RT_EXTRA_CXX_CFLAGS})
  list(APPEND COMPILER_RT_COMMON_CFLAGS ${_COMPILER_RT_EXTRA_CXX_CFLAGS})
endif()
"""
if needle not in text:
    raise SystemExit(f"needle not found in {path}")
path.write_text(text.replace(needle, replacement, 1))
PY
  fi
}

resolve_sysroot_root() {
  if [[ -n "$SYSROOT_ROOT" ]]; then
    printf '%s\n' "$SYSROOT_ROOT"
    return
  fi

  if [[ -d "${PROJECT_ROOT}/prebuild/sysroot-15.2.0" ]]; then
    printf '%s\n' "${PROJECT_ROOT}/prebuild/sysroot-15.2.0"
    return
  fi

  if [[ -z "$SYSROOT_ARCHIVE" ]]; then
    ensure_default_archive \
      SYSROOT_ARCHIVE \
      "sysroot archive" \
      "$CACHE_DIR" \
      "sysroot-15.2.0-linux.tar.xz" \
      "$SYSROOT_URL"
  fi

  local extract_dir="${BUILD_DIR}/prebuild/sysroot"
  extract_archive_once "$SYSROOT_ARCHIVE" "$extract_dir" "sysroot-15.2.0"
  unwrap_single_subdir "$extract_dir" "x86_64-unknown-linux-gnu/sysroot"
}

resolve_bootstrap_clang_root() {
  if [[ -n "$BOOTSTRAP_CLANG_ROOT" ]]; then
    [[ -x "${BOOTSTRAP_CLANG_ROOT}/bin/clang" ]] || die "invalid bootstrap clang root: ${BOOTSTRAP_CLANG_ROOT}"
    printf '%s\n' "$BOOTSTRAP_CLANG_ROOT"
    return
  fi

  if [[ -d "${PROJECT_ROOT}/prebuild/compiler-llvm-18.1.8/llvm-18.1.8" ]]; then
    if [[ -x "${PROJECT_ROOT}/prebuild/compiler-llvm-18.1.8/llvm-18.1.8/bin/clang" ]]; then
      if "${PROJECT_ROOT}/prebuild/compiler-llvm-18.1.8/llvm-18.1.8/bin/clang" --version >/dev/null 2>&1; then
        printf '%s\n' "${PROJECT_ROOT}/prebuild/compiler-llvm-18.1.8/llvm-18.1.8"
        return
      fi
    fi
  fi

  if [[ -z "$BOOTSTRAP_CLANG_ARCHIVE" ]]; then
    local default_bootstrap_url
    default_bootstrap_url="$(default_bootstrap_url_for_arch "$HOST_MACHINE_ARCH")"
    if [[ -n "$default_bootstrap_url" ]]; then
      ensure_default_archive \
        BOOTSTRAP_CLANG_ARCHIVE \
        "bootstrap clang archive for build host ${HOST_MACHINE_ARCH}" \
        "$CACHE_DIR" \
        "compiler-llvm-${LLVM_VERSION}-linux-${HOST_MACHINE_ARCH}.tar.gz" \
        "$default_bootstrap_url"
    else
      printf '%s\n' ""
      return
    fi
  fi

  local extract_dir="${BUILD_DIR}/prebuild/bootstrap-clang"
  extract_archive_once "$BOOTSTRAP_CLANG_ARCHIVE" "$extract_dir" "compiler-llvm-${LLVM_VERSION}"
  unwrap_single_subdir "$extract_dir" "bin/clang"
}

resolve_host_compilers() {
  local bootstrap_root="$1"

  if [[ -n "$bootstrap_root" ]]; then
    [[ -x "${bootstrap_root}/bin/clang" ]] || die "bootstrap clang is not executable: ${bootstrap_root}/bin/clang"
    [[ -x "${bootstrap_root}/bin/clang++" ]] || die "bootstrap clang++ is not executable: ${bootstrap_root}/bin/clang++"
    "${bootstrap_root}/bin/clang" --version >/dev/null 2>&1 || die "failed to execute bootstrap clang: ${bootstrap_root}/bin/clang"
    HOST_CC="${bootstrap_root}/bin/clang"
    HOST_CXX="${bootstrap_root}/bin/clang++"
    HOST_LLD=""
    if [[ -x "${bootstrap_root}/bin/ld.lld" ]]; then
      HOST_LLD="${bootstrap_root}/bin/ld.lld"
    fi
    return
  fi

  HOST_CC="$(command -v cc || true)"
  [[ -n "$HOST_CC" ]] || HOST_CC="$(command -v clang || true)"
  [[ -n "$HOST_CC" ]] || HOST_CC="$(command -v gcc || true)"
  [[ -n "$HOST_CC" ]] || die "could not find a host C compiler"

  HOST_CXX="$(command -v c++ || true)"
  [[ -n "$HOST_CXX" ]] || HOST_CXX="$(command -v clang++ || true)"
  [[ -n "$HOST_CXX" ]] || HOST_CXX="$(command -v g++ || true)"
  [[ -n "$HOST_CXX" ]] || die "could not find a host C++ compiler"

  HOST_LLD=""
  if command -v ld.lld >/dev/null 2>&1; then
    HOST_LLD="$(command -v ld.lld)"
  fi
}

detect_cxa_thread_atexit_impl() {
  local sysroot_dir="$1"
  local reader="$2"
  local libc_candidate=""

  local candidate
  for candidate in \
    "${sysroot_dir}/lib/libc.so.6" \
    "${sysroot_dir}/lib64/libc.so.6" \
    "${sysroot_dir}/usr/lib/libc.so.6" \
    "${sysroot_dir}/usr/lib64/libc.so.6"; do
    if [[ -f "$candidate" ]]; then
      libc_candidate="$candidate"
      break
    fi
  done

  if [[ -z "$libc_candidate" ]]; then
    echo "OFF"
    return
  fi

  if "$reader" -Ws "$libc_candidate" 2>/dev/null | grep -q "__cxa_thread_atexit_impl"; then
    echo "ON"
  else
    echo "OFF"
  fi
}

configure_cmake() {
  local source_dir="$1"
  local build_dir="$2"
  shift 2

  local args=("${GENERATOR_ARGS[@]}")
  if [[ ${#GENERATOR_ARGS[@]} -gt 0 && -n "${GENERATOR_MAKE_PROGRAM:-}" ]]; then
    local cache_path="${build_dir}/CMakeCache.txt"
    if [[ -f "$cache_path" ]]; then
      local cached_make_program
      cached_make_program="$(sed -n 's/^CMAKE_MAKE_PROGRAM:FILEPATH=//p' "$cache_path" | head -n 1)"
      if [[ -n "$cached_make_program" && "$cached_make_program" != "$GENERATOR_MAKE_PROGRAM" ]]; then
        log "Resetting ${build_dir} because cached CMAKE_MAKE_PROGRAM points to ${cached_make_program}"
        cmake -E rm -rf "$build_dir"
      fi
    fi
    args+=("-DCMAKE_MAKE_PROGRAM=${GENERATOR_MAKE_PROGRAM}")
  fi

  cmake "${args[@]}" -S "$source_dir" -B "$build_dir" "$@"
}

build_cmake_target() {
  local build_dir="$1"
  local target_name="$2"
  shift 2

  local args=(
    --build "$build_dir"
    --target "$target_name"
  )

  if [[ -n "$JOBS" ]]; then
    args+=(--parallel "$JOBS")
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    args+=(--verbose)
  fi

  cmake "${args[@]}" "$@"
}

install_cmake_build_dir() {
  local build_dir="$1"
  shift

  local args=(
    --install "$build_dir"
  )

  if [[ -n "$JOBS" ]]; then
    args+=(--parallel "$JOBS")
  fi

  cmake "${args[@]}" "$@"
}

relative_symlink() {
  local source_path="$1"
  local dest_path="$2"
  local dest_dir
  dest_dir="$(dirname "$dest_path")"

  mkdir -p "$dest_dir"
  rm -f "$dest_path"
  local rel_target
  rel_target="$(realpath --relative-to="$dest_dir" "$source_path")"
  ln -s "$rel_target" "$dest_path"
}

find_first_existing_file() {
  local candidate
  for candidate in "$@"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

prepare_bootstrap_resource_overlay() {
  local source_root="$1"
  local target_triple="$2"
  local overlay_dir="$3"

  local builtins_source
  builtins_source="$(find_first_existing_file \
    "${source_root}/usr/lib/${target_triple}/libclang_rt.builtins.a" \
    "${source_root}/usr/lib/libclang_rt.builtins.a" \
    "${source_root}/lib/${target_triple}/libclang_rt.builtins.a" \
    "${source_root}/lib/libclang_rt.builtins.a")" || die "could not find libclang_rt.builtins.a for ${target_triple} under ${source_root}"

  cmake -E rm -rf "$overlay_dir"
  mkdir -p "${overlay_dir}/lib/${target_triple}"

  if [[ -d "${BOOTSTRAP_RESOURCE_DIR}/include" ]]; then
    relative_symlink "${BOOTSTRAP_RESOURCE_DIR}/include" "${overlay_dir}/include"
  fi

  relative_symlink "$builtins_source" "${overlay_dir}/lib/${target_triple}/libclang_rt.builtins.a"
}

ensure_bootstrap_resource_headers_linked() {
  local resource_root="$1"

  if [[ -d "${BOOTSTRAP_RESOURCE_DIR}/include" && ! -e "${resource_root}/include" ]]; then
    relative_symlink "${BOOTSTRAP_RESOURCE_DIR}/include" "${resource_root}/include"
  fi
}

prepare_final_clang_resource_headers_dir() {
  local resource_root="$1"
  local include_dir="${resource_root}/include"

  if [[ -L "$include_dir" ]]; then
    log "Replacing borrowed clang resource headers overlay at ${include_dir} before final install"
    rm -f "$include_dir"
  fi

  mkdir -p "$include_dir"
}

verify_final_clang_resource_headers_dir() {
  local resource_root="$1"
  local include_dir="${resource_root}/include"

  [[ -d "$include_dir" ]] || die "expected clang resource include directory not found: ${include_dir}"
  [[ ! -L "$include_dir" ]] || die "clang resource include directory is still a symlink: ${include_dir}"
  [[ -f "${include_dir}/stddef.h" ]] || die "expected builtin header not found after install: ${include_dir}/stddef.h"
}

write_bootstrap_builder_wrapper() {
  local wrapper_path="$1"
  local driver_path="$2"
  local target_triple="$3"
  local sysroot_dir="$4"
  local resource_dir="$5"
  local crt_dir="$6"
  local runtime_lib_dir="$7"
  local add_cxx_stdlib="$8"
  local add_unwindlib="$9"
  local disable_default_cxx_includes="${10:-0}"
  local cxx_triple_include_dir="${11:-${sysroot_dir}/usr/include/${target_triple}/c++/v1}"
  local cxx_include_dir="${12:-${sysroot_dir}/usr/include/c++/v1}"
  {
    printf '%s\n' '#!/usr/bin/env sh'
    printf '%s\n' 'set -eu'
    printf '%s\n' ''
    printf '%s\n' 'want_link=1'
    printf '%s\n' 'want_cxx_stdlib=1'
    printf '%s\n' 'for arg in "$@"; do'
    printf '%s\n' '  case "$arg" in'
    printf '%s\n' '    -c|-E|-S)'
    printf '%s\n' '      want_link=0'
    printf '%s\n' '      ;;'
    printf '%s\n' '    -nostdinc++)'
    printf '%s\n' '      want_cxx_stdlib=0'
    printf '%s\n' '      ;;'
    printf '%s\n' '  esac'
    printf '%s\n' 'done'
    printf '%s\n' ''
    if [[ "$disable_default_cxx_includes" == "1" ]]; then
      printf '%s\n' 'set -- "-nostdinc++" "$@"'
      printf '%s\n' ''
    fi
    if [[ "$add_cxx_stdlib" == "1" ]]; then
      printf '%s\n' 'if [ "$want_cxx_stdlib" -eq 1 ]; then'
      printf '  set -- "-nostdinc++" "-isystem%s" "-isystem%s" "$@"\n' "$cxx_triple_include_dir" "$cxx_include_dir"
      printf '%s\n' 'fi'
      printf '%s\n' ''
    fi
    printf '%s\n' 'if [ "$want_link" -eq 1 ]; then'
    if [[ "$add_cxx_stdlib" == "1" ]]; then
      printf '%s\n' '  if [ "$want_cxx_stdlib" -eq 1 ]; then'
      printf '%s\n' '    set -- "-stdlib=libc++" "$@"'
      printf '%s\n' '  fi'
    fi
    printf '  exec "%s" \\\n' "$driver_path"
    printf '    "--target=%s" \\\n' "$target_triple"
    printf '    "--sysroot=%s" \\\n' "$sysroot_dir"
    printf '    "-resource-dir=%s" \\\n' "$resource_dir"
    printf '    "-B%s" \\\n' "$crt_dir"
    printf '    "-isystem%s/usr/include/%s" \\\n' "$sysroot_dir" "$target_triple"
    if [[ "$add_unwindlib" == "1" ]]; then
      printf '%s\n' '    "--unwindlib=libunwind" \'
    fi
    printf '%s\n' '    "-fuse-ld=lld" \'
    printf '%s\n' '    "--rtlib=compiler-rt" \'
    printf '    "-L%s" \\\n' "$runtime_lib_dir"
    printf '    "-L%s/usr/lib/%s" \\\n' "$sysroot_dir" "$target_triple"
    printf '    "-L%s/usr/lib" \\\n' "$sysroot_dir"
    printf '    "-L%s/lib64" \\\n' "$sysroot_dir"
    printf '    "-L%s/lib" \\\n' "$sysroot_dir"
    printf '%s\n' '    "$@"'
    printf '%s\n' 'else'
    printf '  exec "%s" \\\n' "$driver_path"
    printf '    "--target=%s" \\\n' "$target_triple"
    printf '    "--sysroot=%s" \\\n' "$sysroot_dir"
    printf '    "-resource-dir=%s" \\\n' "$resource_dir"
    printf '    "-B%s" \\\n' "$crt_dir"
    printf '    "-isystem%s/usr/include/%s" \\\n' "$sysroot_dir" "$target_triple"
    printf '%s\n' '    "$@"'
    printf '%s\n' 'fi'
  } > "$wrapper_path"

  chmod +x "$wrapper_path"
}

stage_target_runtime_overlay() {
  local toolchain_root="$1"
  local target_triple="$2"

  local source_libdir="${toolchain_root}/lib/${target_triple}"
  local resource_root="${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}"
  local resource_libdir="${resource_root}/lib/${target_triple}"
  local legacy_resource_libdir="${resource_root}/${target_triple}"
  local builtins="${source_libdir}/libclang_rt.builtins.a"
  local crtbegin="${source_libdir}/clang_rt.crtbegin.o"
  local crtend="${source_libdir}/clang_rt.crtend.o"
  local runtime_path
  local overlay_path

  [[ -d "$source_libdir" ]] || die "runtime library directory not found for ${target_triple}: ${source_libdir}"
  [[ -f "$builtins" ]] || die "compiler-rt builtins not found for ${target_triple}: ${builtins}"
  [[ -f "$crtbegin" ]] || die "compiler-rt crtbegin not found for ${target_triple}: ${crtbegin}"
  [[ -f "$crtend" ]] || die "compiler-rt crtend not found for ${target_triple}: ${crtend}"

  mkdir -p "$resource_libdir"
  ensure_bootstrap_resource_headers_linked "$resource_root"
  if [[ -L "$legacy_resource_libdir" ]]; then
    rm -f "$legacy_resource_libdir"
  elif [[ -d "$legacy_resource_libdir" ]] && [[ ! "$legacy_resource_libdir" -ef "$resource_libdir" ]]; then
    cmake -E rm -rf "$legacy_resource_libdir"
  fi

  for runtime_path in "${source_libdir}"/*; do
    [[ -e "$runtime_path" ]] || continue
    overlay_path="${resource_libdir}/$(basename "$runtime_path")"
    if [[ -e "$overlay_path" && ! -L "$overlay_path" ]]; then
      continue
    fi
    relative_symlink "$runtime_path" "$overlay_path"
  done

  local crtbegin_name
  for crtbegin_name in crtbegin.o crtbeginS.o crtbeginT.o; do
    overlay_path="${resource_libdir}/${crtbegin_name}"
    if [[ ! -e "$overlay_path" || -L "$overlay_path" ]]; then
      relative_symlink "$crtbegin" "$overlay_path"
    fi
  done

  local crtend_name
  for crtend_name in crtend.o crtendS.o; do
    overlay_path="${resource_libdir}/${crtend_name}"
    if [[ ! -e "$overlay_path" || -L "$overlay_path" ]]; then
      relative_symlink "$crtend" "$overlay_path"
    fi
  done
}

write_clang_driver_config() {
  local config_path="$1"
  local target_triple="$2"
  local add_cxx_stdlib="$3"

  cat > "$config_path" <<EOF
# Default cross configuration for ${target_triple}.
--target=${target_triple}
--sysroot=<CFGDIR>/../../sysroot/${target_triple}
-resource-dir=<CFGDIR>/../lib/clang/${LLVM_RESOURCE_VERSION}
-B<CFGDIR>/../lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}
\$--rtlib=compiler-rt
\$--unwindlib=libunwind
\$-fuse-ld=lld
\$-L<CFGDIR>/../lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}
EOF

  if [[ "$add_cxx_stdlib" == "1" ]]; then
    printf '%s\n' '-stdlib=libc++' >> "$config_path"
  fi
}

create_target_driver_configs() {
  local toolchain_root="$1"
  local bin_dir="${toolchain_root}/bin"

  local triple
  for triple in "${ALL_TARGET_TRIPLES[@]}"; do
    write_clang_driver_config "${bin_dir}/${triple}-clang-gcc.cfg" "$triple" "0"
    write_clang_driver_config "${bin_dir}/${triple}-clang-g++.cfg" "$triple" "1"

    ln -sfn "clang" "${bin_dir}/${triple}-clang-gcc"
    ln -sfn "clang++" "${bin_dir}/${triple}-clang-g++"

    ln -sfn "llvm-ar" "${bin_dir}/${triple}-ar"
    ln -sfn "llvm-nm" "${bin_dir}/${triple}-nm"
    ln -sfn "llvm-objcopy" "${bin_dir}/${triple}-objcopy"
    ln -sfn "llvm-ranlib" "${bin_dir}/${triple}-ranlib"
    ln -sfn "llvm-strip" "${bin_dir}/${triple}-strip"
  done
}

build_host_llvm() {
  local llvm_source_root="$1"
  local toolchain_root="$2"
  local host_target_sysroot="$3"
  local host_wrapper_root="${BUILD_DIR}/toolchain/host-llvm/${TARGET_TRIPLE}"
  local host_resource_dir="${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}"
  local host_crt_dir="${host_resource_dir}/lib/${TARGET_TRIPLE}"
  local host_cc_wrapper="${host_wrapper_root}/clang"
  local host_cxx_wrapper="${host_wrapper_root}/clang++"
  local llvm_target_arch
  llvm_target_arch="$(llvm_native_target_name_for_arch "$ARCH")"

  local host_build_dir="${BUILD_DIR}/llvm-host"
  local host_install_rpath="\$ORIGIN;\$ORIGIN/../lib;\$ORIGIN/${TARGET_TRIPLE};\$ORIGIN/../lib/${TARGET_TRIPLE}"
  cmake -E make_directory "$host_build_dir"

  mkdir -p "$host_wrapper_root"
  write_bootstrap_builder_wrapper \
    "$host_cc_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang" \
    "$TARGET_TRIPLE" \
    "$host_target_sysroot" \
    "$host_resource_dir" \
    "$host_crt_dir" \
    "${host_target_sysroot}/usr/lib/${TARGET_TRIPLE}" \
    "0" \
    "1"
  write_bootstrap_builder_wrapper \
    "$host_cxx_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang++" \
    "$TARGET_TRIPLE" \
    "$host_target_sysroot" \
    "$host_resource_dir" \
    "$host_crt_dir" \
    "${host_target_sysroot}/usr/lib/${TARGET_TRIPLE}" \
    "1" \
    "1"

  local host_cmake_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR="${ARCH}"
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DCMAKE_C_FLAGS_INIT=-pthread
    -DCMAKE_CXX_FLAGS_INIT=-pthread
    "-DCMAKE_EXE_LINKER_FLAGS_INIT=-pthread -Wl,--disable-new-dtags"
    "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-pthread -Wl,--disable-new-dtags"
    "-DCMAKE_MODULE_LINKER_FLAGS_INIT=-pthread -Wl,--disable-new-dtags"
    -DCMAKE_INSTALL_PREFIX="${toolchain_root}"
    "-DCMAKE_INSTALL_RPATH=${host_install_rpath}"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    "-DCMAKE_SYSROOT=${host_target_sysroot}"
    "-DCMAKE_FIND_ROOT_PATH=${host_target_sysroot}"
    "-DCMAKE_PREFIX_PATH=${host_target_sysroot}/usr;${host_target_sysroot}"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DLLVM_ENABLE_PROJECTS=clang\;clang-tools-extra\;lld
    -DLLVM_TARGETS_TO_BUILD=X86\;AArch64\;RISCV
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=WebAssembly\;LoongArch
    -DLLVM_HOST_TRIPLE="${TARGET_TRIPLE}"
    -DLLVM_TARGET_ARCH="${llvm_target_arch}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    "-DLLVM_NATIVE_TOOL_DIR=${BOOTSTRAP_CLANG_ROOT}/bin"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_INSTALL_UTILS=ON
    -DLLVM_ENABLE_TERMINFO=OFF
    -DLLVM_ENABLE_LIBXML2=ON
    -DLLVM_ENABLE_LIBCXX=ON
    -DLLVM_ENABLE_ZLIB=ON
    -DLLVM_ENABLE_ZSTD=ON
    "-DPython3_EXECUTABLE=${HOST_PYTHON3}"
    -DLLVM_ENABLE_RTTI=ON
    -DLLVM_BUILD_LLVM_DYLIB=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
    -DCLANG_LINK_CLANG_DYLIB=ON
    -DCLANG_DEFAULT_LINKER=lld
    -DCLANG_DEFAULT_CXX_STDLIB=libc++
    -DCLANG_DEFAULT_RTLIB=compiler-rt
    -DCLANG_DEFAULT_UNWINDLIB=libunwind
    -DCMAKE_C_COMPILER="${host_cc_wrapper}"
    -DCMAKE_CXX_COMPILER="${host_cxx_wrapper}"
    -DCMAKE_ASM_COMPILER="${host_cc_wrapper}"
    "-DCMAKE_AR=${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ar"
    "-DCMAKE_NM=${BOOTSTRAP_CLANG_ROOT}/bin/llvm-nm"
    "-DCMAKE_OBJCOPY=${BOOTSTRAP_CLANG_ROOT}/bin/llvm-objcopy"
    "-DCMAKE_RANLIB=${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ranlib"
    "-DCMAKE_STRIP=${BOOTSTRAP_CLANG_ROOT}/bin/llvm-strip"
  )
  host_cmake_args+=("-DCMAKE_LINKER=${BOOTSTRAP_CLANG_ROOT}/bin/ld.lld")

  if [[ "$VERBOSE" -eq 1 ]]; then
    host_cmake_args+=(-DCMAKE_VERBOSE_MAKEFILE=ON)
  fi

  if [[ ${#HOST_CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
    host_cmake_args+=("${HOST_CMAKE_EXTRA_ARGS[@]}")
  fi

  log "Configuring host LLVM/Clang for ${TARGET_TRIPLE}"
  configure_cmake "${llvm_source_root}/llvm" "${host_build_dir}" "${host_cmake_args[@]}"

  log "Building host LLVM/Clang for ${TARGET_TRIPLE}"
  build_cmake_target "${host_build_dir}" all

  prepare_final_clang_resource_headers_dir "$host_resource_dir"

  log "Installing host LLVM/Clang for ${TARGET_TRIPLE}"
  install_cmake_build_dir "${host_build_dir}"

  verify_final_clang_resource_headers_dir "$host_resource_dir"
}

build_target_compiler_rt() {
  local llvm_source_root="$1"
  local toolchain_root="$2"
  local staged_sysroot="$3"
  local target_triple="$4"
  local phase="${5:-final}"

  local build_dir
  local wrapper_root
  local resource_dir
  local crt_dir
  local runtime_lib_dir
  local compiler_rt_shared_linker_flags="-fuse-ld=lld"
  local build_builtins="OFF"
  local build_crt="OFF"
  local build_sanitizers="ON"
  local build_xray="ON"
  local build_libfuzzer="ON"
  local build_profile="ON"
  local build_memprof="ON"
  local build_gwp_asan="ON"
  local build_orc="ON"
  local use_builtins_library="ON"
  local sanitizer_cxx_abi="libcxxabi"
  local should_stage_overlay="0"
  local compiler_rt_install_library_dir=""
  local cxx_triple_include_dir="${staged_sysroot}/usr/include/${target_triple}/c++/v1"
  local cxx_include_dir="${staged_sysroot}/usr/include/c++/v1"

  case "$phase" in
    bootstrap)
      build_dir="${BUILD_DIR}/llvm-runtimes/${target_triple}/compiler-rt-bootstrap"
      wrapper_root="${BUILD_DIR}/toolchain/runtime-builders/${target_triple}/compiler-rt-bootstrap"
      resource_dir="${BOOTSTRAP_RESOURCE_DIR}"
      crt_dir="${staged_sysroot}/usr/lib/${target_triple}"
      runtime_lib_dir="${staged_sysroot}/usr/lib/${target_triple}"
      compiler_rt_shared_linker_flags="-fuse-ld=lld -nostartfiles"
      build_builtins="ON"
      build_crt="ON"
      build_sanitizers="OFF"
      build_xray="OFF"
      build_libfuzzer="OFF"
      build_profile="OFF"
      build_memprof="OFF"
      build_gwp_asan="OFF"
      build_orc="OFF"
      use_builtins_library="OFF"
      sanitizer_cxx_abi="default"
      should_stage_overlay="1"
      ;;
    final)
      build_dir="${BUILD_DIR}/llvm-runtimes/${target_triple}/compiler-rt"
      wrapper_root="${BUILD_DIR}/toolchain/runtime-builders/${target_triple}/compiler-rt"
      resource_dir="${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}"
      crt_dir="${resource_dir}/lib/${target_triple}"
      runtime_lib_dir="${resource_dir}/lib/${target_triple}"
      compiler_rt_install_library_dir="${resource_dir}/lib"
      build_builtins="ON"
      cxx_triple_include_dir="${toolchain_root}/include/${target_triple}/c++/v1"
      cxx_include_dir="${toolchain_root}/include/c++/v1"
      ;;
    *)
      die "unsupported compiler-rt build phase: ${phase}"
      ;;
  esac

  local cc_wrapper="${wrapper_root}/clang"
  local cxx_wrapper="${wrapper_root}/clang++"
  cmake -E make_directory "$build_dir"
  mkdir -p "$wrapper_root"
  write_bootstrap_builder_wrapper \
    "$cc_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang" \
    "$target_triple" \
    "$staged_sysroot" \
    "${resource_dir}" \
    "${crt_dir}" \
    "${runtime_lib_dir}" \
    "0" \
    "0"
  write_bootstrap_builder_wrapper \
    "$cxx_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang++" \
    "$target_triple" \
    "$staged_sysroot" \
    "${resource_dir}" \
    "${crt_dir}" \
    "${runtime_lib_dir}" \
    "1" \
    "0" \
    "0" \
    "${cxx_triple_include_dir}" \
    "${cxx_include_dir}"

  local common_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR="${target_triple%%-*}"
    -DCMAKE_INSTALL_PREFIX="${toolchain_root}"
    -DCMAKE_C_COMPILER="${cc_wrapper}"
    -DCMAKE_CXX_COMPILER="${cxx_wrapper}"
    -DCMAKE_ASM_COMPILER="${cc_wrapper}"
    -DCMAKE_LINKER="${BOOTSTRAP_CLANG_ROOT}/bin/ld.lld"
    -DCMAKE_AR="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ar"
    -DCMAKE_NM="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-nm"
    -DCMAKE_OBJCOPY="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-objcopy"
    -DCMAKE_RANLIB="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ranlib"
    -DCMAKE_STRIP="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-strip"
    -DCMAKE_C_COMPILER_TARGET="${target_triple}"
    -DCMAKE_CXX_COMPILER_TARGET="${target_triple}"
    -DCMAKE_ASM_COMPILER_TARGET="${target_triple}"
    -DCMAKE_SYSROOT="${staged_sysroot}"
    "-DCMAKE_FIND_ROOT_PATH=${staged_sysroot}"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld
    "-DCMAKE_SHARED_LINKER_FLAGS=${compiler_rt_shared_linker_flags}"
    "-DCMAKE_MODULE_LINKER_FLAGS=${compiler_rt_shared_linker_flags}"
    -DLLVM_PATH="${llvm_source_root}/llvm"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${target_triple}"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
    -DLIBUNWIND_INCLUDE_TESTS=OFF
    -DLIBCXXABI_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF
    -DLIBCXX_CXX_ABI=libcxxabi
    -DLLVM_ENABLE_RUNTIMES=compiler-rt
    "-DPYTHON_EXECUTABLE=${HOST_PYTHON3}"
    "-DPython3_EXECUTABLE=${HOST_PYTHON3}"
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
    "-DSANITIZER_CXX_ABI=${sanitizer_cxx_abi}"
    "-DCOMPILER_RT_USE_BUILTINS_LIBRARY=${use_builtins_library}"
    "-DCOMPILER_RT_BUILD_BUILTINS=${build_builtins}"
    "-DCOMPILER_RT_BUILD_CRT=${build_crt}"
    "-DCOMPILER_RT_BUILD_SANITIZERS=${build_sanitizers}"
    "-DCOMPILER_RT_BUILD_XRAY=${build_xray}"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=${build_libfuzzer}"
    "-DCOMPILER_RT_BUILD_PROFILE=${build_profile}"
    "-DCOMPILER_RT_BUILD_MEMPROF=${build_memprof}"
    "-DCOMPILER_RT_BUILD_GWP_ASAN=${build_gwp_asan}"
    "-DCOMPILER_RT_BUILD_ORC=${build_orc}"
  )

  if [[ "$VERBOSE" -eq 1 ]]; then
    common_args+=(-DCMAKE_VERBOSE_MAKEFILE=ON)
  fi

  if [[ ${#RUNTIME_CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
    common_args+=("${RUNTIME_CMAKE_EXTRA_ARGS[@]}")
  fi

  if [[ -n "$compiler_rt_install_library_dir" ]]; then
    common_args+=("-DCOMPILER_RT_INSTALL_LIBRARY_DIR=${compiler_rt_install_library_dir}")
  fi

  log "Configuring compiler-rt (${phase}) for ${target_triple}"
  configure_cmake "${llvm_source_root}/runtimes" "${build_dir}" "${common_args[@]}"

  log "Building compiler-rt (${phase}) for ${target_triple}"
  build_cmake_target "${build_dir}" install

  if [[ "$phase" == "final" || "$should_stage_overlay" == "1" ]]; then
    stage_target_runtime_overlay "$toolchain_root" "$target_triple"
  fi
}

build_target_libunwind() {
  local llvm_source_root="$1"
  local toolchain_root="$2"
  local staged_sysroot="$3"
  local target_triple="$4"

  local build_dir="${BUILD_DIR}/llvm-runtimes/${target_triple}/libunwind"
  local wrapper_root="${BUILD_DIR}/toolchain/runtime-builders/${target_triple}/libunwind"
  local cc_wrapper="${wrapper_root}/clang"
  local cxx_wrapper="${wrapper_root}/clang++"

  cmake -E make_directory "$build_dir"
  mkdir -p "$wrapper_root"
  write_bootstrap_builder_wrapper \
    "$cc_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang" \
    "$target_triple" \
    "$staged_sysroot" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "0" \
    "0"
  write_bootstrap_builder_wrapper \
    "$cxx_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang++" \
    "$target_triple" \
    "$staged_sysroot" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "1" \
    "0"

  local common_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR="${target_triple%%-*}"
    -DCMAKE_INSTALL_PREFIX="${toolchain_root}"
    -DCMAKE_C_COMPILER="${cc_wrapper}"
    -DCMAKE_CXX_COMPILER="${cxx_wrapper}"
    -DCMAKE_ASM_COMPILER="${cc_wrapper}"
    -DCMAKE_LINKER="${BOOTSTRAP_CLANG_ROOT}/bin/ld.lld"
    -DCMAKE_AR="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ar"
    -DCMAKE_NM="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-nm"
    -DCMAKE_OBJCOPY="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-objcopy"
    -DCMAKE_RANLIB="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ranlib"
    -DCMAKE_STRIP="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-strip"
    -DCMAKE_SYSROOT="${staged_sysroot}"
    "-DCMAKE_FIND_ROOT_PATH=${staged_sysroot}"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DLLVM_PATH="${llvm_source_root}/llvm"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${target_triple}"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
    -DLIBUNWIND_INCLUDE_TESTS=OFF
    -DLIBCXXABI_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF
    -DLIBCXX_CXX_ABI=libcxxabi
    -DLLVM_ENABLE_RUNTIMES=libunwind
    -DLIBUNWIND_USE_COMPILER_RT=ON
  )

  if [[ "$VERBOSE" -eq 1 ]]; then
    common_args+=(-DCMAKE_VERBOSE_MAKEFILE=ON)
  fi

  if [[ ${#RUNTIME_CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
    common_args+=("${RUNTIME_CMAKE_EXTRA_ARGS[@]}")
  fi

  log "Configuring libunwind for ${target_triple}"
  configure_cmake "${llvm_source_root}/runtimes" "${build_dir}" "${common_args[@]}"

  log "Building libunwind for ${target_triple}"
  build_cmake_target "${build_dir}" install
  stage_target_runtime_overlay "$toolchain_root" "$target_triple"
}

build_target_cxx_runtimes() {
  local llvm_source_root="$1"
  local toolchain_root="$2"
  local staged_sysroot="$3"
  local target_triple="$4"
  local libcxxabi_has_tls_dtor="$5"

  local build_dir="${BUILD_DIR}/llvm-runtimes/${target_triple}/cxx"
  local wrapper_root="${BUILD_DIR}/toolchain/runtime-builders/${target_triple}/cxx"
  local cc_wrapper="${wrapper_root}/clang"
  local cxx_wrapper="${wrapper_root}/clang++"

  cmake -E make_directory "$build_dir"
  mkdir -p "$wrapper_root"
  write_bootstrap_builder_wrapper \
    "$cc_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang" \
    "$target_triple" \
    "$staged_sysroot" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "0" \
    "1" \
    "1"
  write_bootstrap_builder_wrapper \
    "$cxx_wrapper" \
    "${BOOTSTRAP_CLANG_ROOT}/bin/clang++" \
    "$target_triple" \
    "$staged_sysroot" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "${toolchain_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${target_triple}" \
    "0" \
    "1" \
    "1"

  local common_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR="${target_triple%%-*}"
    -DCMAKE_INSTALL_PREFIX="${toolchain_root}"
    -DCMAKE_C_COMPILER="${cc_wrapper}"
    -DCMAKE_CXX_COMPILER="${cxx_wrapper}"
    -DCMAKE_ASM_COMPILER="${cc_wrapper}"
    -DCMAKE_LINKER="${BOOTSTRAP_CLANG_ROOT}/bin/ld.lld"
    -DCMAKE_AR="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ar"
    -DCMAKE_NM="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-nm"
    -DCMAKE_OBJCOPY="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-objcopy"
    -DCMAKE_RANLIB="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-ranlib"
    -DCMAKE_STRIP="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-strip"
    -DCMAKE_SYSROOT="${staged_sysroot}"
    "-DCMAKE_FIND_ROOT_PATH=${staged_sysroot}"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DLLVM_PATH="${llvm_source_root}/llvm"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${target_triple}"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
    -DLIBUNWIND_INCLUDE_TESTS=OFF
    -DLIBCXXABI_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF
    -DLIBCXX_CXX_ABI=libcxxabi
    -DLLVM_ENABLE_RUNTIMES=libunwind\;libcxxabi\;libcxx
    -DLIBUNWIND_USE_COMPILER_RT=ON
    -DLIBCXXABI_USE_COMPILER_RT=ON
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON
    -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL="${libcxxabi_has_tls_dtor}"
    -DLIBCXX_USE_COMPILER_RT=ON
  )

  if [[ "$VERBOSE" -eq 1 ]]; then
    common_args+=(-DCMAKE_VERBOSE_MAKEFILE=ON)
  fi

  if [[ ${#RUNTIME_CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
    common_args+=("${RUNTIME_CMAKE_EXTRA_ARGS[@]}")
  fi

  log "Configuring libc++/libc++abi for ${target_triple}"
  configure_cmake "${llvm_source_root}/runtimes" "${build_dir}" "${common_args[@]}"

  log "Building libc++/libc++abi for ${target_triple}"
  build_cmake_target "${build_dir}" install
  stage_target_runtime_overlay "$toolchain_root" "$target_triple"
}

ARCH=""
CLEAN=0
JOBS=""
VERBOSE=0
DOWNLOAD_MISSING=0
BUILD_DIR=""
DIST_DIR=""
INPUT_ROOTFS_DIR=""
INSTALL_PREFIX="${DEFAULT_INSTALL_PREFIX}"
SYSROOT_PREFIX="${DEFAULT_SYSROOT_PREFIX}"
SYSROOT_ROOT=""
SYSROOT_ARCHIVE=""
LLVM_SOURCE_DIR=""
LLVM_ARCHIVE=""
BOOTSTRAP_CLANG_ROOT=""
BOOTSTRAP_CLANG_ARCHIVE=""
HOST_CMAKE_EXTRA_ARGS=()
RUNTIME_CMAKE_EXTRA_ARGS=()

CACHE_DIR="${PROJECT_ROOT}/cache"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch=*)
      ARCH="${1#*=}"
      ;;
    --arch)
      shift
      [[ $# -gt 0 ]] || die "--arch requires a value"
      ARCH="$1"
      ;;
    --clean)
      CLEAN=1
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --verbose)
      VERBOSE=1
      ;;
    --download-missing)
      DOWNLOAD_MISSING=1
      ;;
    --build-dir=*)
      BUILD_DIR="${1#*=}"
      ;;
    --build-dir)
      shift
      [[ $# -gt 0 ]] || die "--build-dir requires a value"
      BUILD_DIR="$1"
      ;;
    --dist-dir=*)
      DIST_DIR="${1#*=}"
      ;;
    --dist-dir)
      shift
      [[ $# -gt 0 ]] || die "--dist-dir requires a value"
      DIST_DIR="$1"
      ;;
    --input-rootfs-dir=*)
      INPUT_ROOTFS_DIR="${1#*=}"
      ;;
    --input-rootfs-dir)
      shift
      [[ $# -gt 0 ]] || die "--input-rootfs-dir requires a value"
      INPUT_ROOTFS_DIR="$1"
      ;;
    --install-prefix=*)
      INSTALL_PREFIX="${1#*=}"
      ;;
    --install-prefix)
      shift
      [[ $# -gt 0 ]] || die "--install-prefix requires a value"
      INSTALL_PREFIX="$1"
      ;;
    --sysroot-prefix=*)
      SYSROOT_PREFIX="${1#*=}"
      ;;
    --sysroot-prefix)
      shift
      [[ $# -gt 0 ]] || die "--sysroot-prefix requires a value"
      SYSROOT_PREFIX="$1"
      ;;
    --sysroot-root=*)
      SYSROOT_ROOT="${1#*=}"
      ;;
    --sysroot-root)
      shift
      [[ $# -gt 0 ]] || die "--sysroot-root requires a value"
      SYSROOT_ROOT="$1"
      ;;
    --sysroot-archive=*)
      SYSROOT_ARCHIVE="${1#*=}"
      ;;
    --sysroot-archive)
      shift
      [[ $# -gt 0 ]] || die "--sysroot-archive requires a value"
      SYSROOT_ARCHIVE="$1"
      ;;
    --llvm-source-dir=*)
      LLVM_SOURCE_DIR="${1#*=}"
      ;;
    --llvm-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--llvm-source-dir requires a value"
      LLVM_SOURCE_DIR="$1"
      ;;
    --llvm-archive=*)
      LLVM_ARCHIVE="${1#*=}"
      ;;
    --llvm-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvm-archive requires a value"
      LLVM_ARCHIVE="$1"
      ;;
    --bootstrap-clang-root=*)
      BOOTSTRAP_CLANG_ROOT="${1#*=}"
      ;;
    --bootstrap-clang-root)
      shift
      [[ $# -gt 0 ]] || die "--bootstrap-clang-root requires a value"
      BOOTSTRAP_CLANG_ROOT="$1"
      ;;
    --bootstrap-clang-archive=*)
      BOOTSTRAP_CLANG_ARCHIVE="${1#*=}"
      ;;
    --bootstrap-clang-archive)
      shift
      [[ $# -gt 0 ]] || die "--bootstrap-clang-archive requires a value"
      BOOTSTRAP_CLANG_ARCHIVE="$1"
      ;;
    --cmake-arg=*)
      HOST_CMAKE_EXTRA_ARGS+=("${1#*=}")
      ;;
    --cmake-arg)
      shift
      [[ $# -gt 0 ]] || die "--cmake-arg requires a value"
      HOST_CMAKE_EXTRA_ARGS+=("$1")
      ;;
    --runtime-cmake-arg=*)
      RUNTIME_CMAKE_EXTRA_ARGS+=("${1#*=}")
      ;;
    --runtime-cmake-arg)
      shift
      [[ $# -gt 0 ]] || die "--runtime-cmake-arg requires a value"
      RUNTIME_CMAKE_EXTRA_ARGS+=("$1")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$ARCH" ]] || die "--arch is required"

require_command cmake
require_command cp
require_command tar
require_command sha256sum
require_command uname
require_command realpath
require_command python3

ARCH="$(normalize_arch "$ARCH")"
TARGET_TRIPLE="$(target_triple_for_arch "$ARCH")"
HOST_MACHINE_ARCH="$(normalize_arch "$(uname -m)")"
HOST_PYTHON3="$(command -v python3)"

if [[ -z "$BUILD_DIR" ]]; then
  BUILD_DIR="${ROOT_DIR}/build/${ARCH}"
fi

if [[ -z "$DIST_DIR" ]]; then
  DIST_DIR="${PROJECT_ROOT}/dist/stage_llvm/${ARCH}"
fi

if [[ -z "$INPUT_ROOTFS_DIR" ]]; then
  INPUT_ROOTFS_DIR="${PROJECT_ROOT}/dist/stage_python/${ARCH}"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  log "Cleaning build directory: ${BUILD_DIR}"
  cmake -E rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"
[[ -d "$INPUT_ROOTFS_DIR" ]] || die "input rootfs does not exist: ${INPUT_ROOTFS_DIR}"

GENERATOR_MAKE_PROGRAM=""
if command -v ninja >/dev/null 2>&1; then
  GENERATOR_ARGS=(-G Ninja)
  GENERATOR_MAKE_PROGRAM="$(command -v ninja)"
else
  GENERATOR_ARGS=()
fi

LLVM_SOURCE_ROOT="$(resolve_llvm_source_dir)"
apply_llvm_source_patches "$LLVM_SOURCE_ROOT"
SYSROOT_SOURCE_ROOT="$(resolve_sysroot_root)"
BOOTSTRAP_CLANG_ROOT="$(resolve_bootstrap_clang_root)"

resolve_host_compilers "$BOOTSTRAP_CLANG_ROOT"
BOOTSTRAP_RESOURCE_DIR="$("${BOOTSTRAP_CLANG_ROOT}/bin/clang" --print-resource-dir)"

ROOTFS_OUT="${BUILD_DIR}/out/${TARGET_TRIPLE}/rootfs"
TOOLCHAIN_ROOT="$(path_under_rootfs "$ROOTFS_OUT" "$INSTALL_PREFIX")"
SYSROOTS_ROOT="$(path_under_rootfs "$ROOTFS_OUT" "$SYSROOT_PREFIX")"

log "Preparing rootfs from ${INPUT_ROOTFS_DIR}"
copy_tree_clean "$INPUT_ROOTFS_DIR" "$ROOTFS_OUT"

mkdir -p "$TOOLCHAIN_ROOT" "$SYSROOTS_ROOT"

log "Staging target sysroots into ${SYSROOT_PREFIX}"
for target_triple in "${ALL_TARGET_TRIPLES[@]}"; do
  source_sysroot="${SYSROOT_SOURCE_ROOT}/${target_triple}/sysroot"
  [[ -d "$source_sysroot" ]] || die "missing sysroot for ${target_triple}: ${source_sysroot}"
  copy_tree_clean "$source_sysroot" "${SYSROOTS_ROOT}/${target_triple}"
done

log "Build machine arch: ${HOST_MACHINE_ARCH}"
log "Final clang host arch: ${ARCH}"
log "Host build compiler: ${HOST_CC}"
log "Host build C++ compiler: ${HOST_CXX}"
if [[ -n "$BOOTSTRAP_CLANG_ROOT" ]]; then
  log "Bootstrap clang root: ${BOOTSTRAP_CLANG_ROOT}"
else
  log "Bootstrap clang root: <system compiler fallback>"
fi
log "LLVM source root: ${LLVM_SOURCE_ROOT}"
log "Output rootfs: ${ROOTFS_OUT}"
log "LLVM install prefix: ${INSTALL_PREFIX}"
log "Sysroot prefix: ${SYSROOT_PREFIX}"

log "Bootstrapping compiler-rt for host clang target ${TARGET_TRIPLE}"
build_target_compiler_rt "$LLVM_SOURCE_ROOT" "$TOOLCHAIN_ROOT" "$ROOTFS_OUT" "$TARGET_TRIPLE" bootstrap

READELF_BIN="$(command -v readelf || true)"
if [[ -z "$READELF_BIN" && -x "${BOOTSTRAP_CLANG_ROOT}/bin/llvm-readelf" ]]; then
  READELF_BIN="${BOOTSTRAP_CLANG_ROOT}/bin/llvm-readelf"
fi
[[ -n "$READELF_BIN" ]] || die "could not find readelf or llvm-readelf"

for target_triple in "${ALL_TARGET_TRIPLES[@]}"; do
  staged_sysroot="${SYSROOTS_ROOT}/${target_triple}"
  libcxxabi_has_tls_dtor="$(detect_cxa_thread_atexit_impl "$staged_sysroot" "$READELF_BIN")"

  build_target_compiler_rt "$LLVM_SOURCE_ROOT" "$TOOLCHAIN_ROOT" "$staged_sysroot" "$target_triple" bootstrap
  build_target_libunwind "$LLVM_SOURCE_ROOT" "$TOOLCHAIN_ROOT" "$staged_sysroot" "$target_triple"
  build_target_cxx_runtimes "$LLVM_SOURCE_ROOT" "$TOOLCHAIN_ROOT" "$staged_sysroot" "$target_triple" "$libcxxabi_has_tls_dtor"
  build_target_compiler_rt "$LLVM_SOURCE_ROOT" "$TOOLCHAIN_ROOT" "$staged_sysroot" "$target_triple" final
done

log "Building final host LLVM/Clang for ${TARGET_TRIPLE} after runtimes"
build_host_llvm "$LLVM_SOURCE_ROOT" "$TOOLCHAIN_ROOT" "$ROOTFS_OUT"

[[ -x "${TOOLCHAIN_ROOT}/bin/clang" ]] || die "expected installed clang not found: ${TOOLCHAIN_ROOT}/bin/clang"
[[ -x "${TOOLCHAIN_ROOT}/bin/ld.lld" ]] || die "expected installed lld not found: ${TOOLCHAIN_ROOT}/bin/ld.lld"

log "Creating target clang driver config files"
create_target_driver_configs "$TOOLCHAIN_ROOT"

log "Copying final rootfs to ${DIST_DIR}"
copy_tree_clean "$ROOTFS_OUT" "$DIST_DIR"

log "stage_llvm rootfs is ready at ${DIST_DIR}"
