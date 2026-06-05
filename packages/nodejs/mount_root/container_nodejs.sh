#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

download_archive() {
  local url="$1"
  local archive_name="$2"

  mkdir -p "$CACHE_DIR"
  if [[ ! -s "${CACHE_DIR}/${archive_name}" ]]; then
    rm -f "${CACHE_DIR:?}/${archive_name}" "${CACHE_DIR}/${archive_name}.tmp"
    log "Downloading ${archive_name}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive_name}.tmp" "$url"
    mv "${CACHE_DIR}/${archive_name}.tmp" "${CACHE_DIR}/${archive_name}"
  fi
}

extract_archive_source() {
  local source_dir="$1"
  local archive_path="$2"
  local marker_path="$3"
  local archive_name=""
  local archive_marker="${source_dir}/.source-archive"

  archive_name="$(basename "$archive_path")"
  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xf "$archive_path" -C "$source_dir" --strip-components=1
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

apply_source_patch_once() {
  local source_dir="$1"
  local patch_path="$2"
  local marker_path=""

  [[ -d "$source_dir" ]] || die "source directory not found: ${source_dir}"
  [[ -f "$patch_path" ]] || die "patch not found: ${patch_path}"

  marker_path="${source_dir}/.develop-suit-$(basename "$patch_path").applied"
  if [[ ! -f "$marker_path" ]]; then
    (
      cd "$source_dir"
      patch -p1 -i "$patch_path"
    )
    touch "$marker_path"
  fi
}

verify_source_contains() {
  local source_dir="$1"
  local relative_path="$2"
  local expected_text="$3"

  [[ -f "${source_dir}/${relative_path}" ]] || die "patched source file not found: ${source_dir}/${relative_path}"
  grep -Fq "$expected_text" "${source_dir}/${relative_path}" \
    || die "patched source verification failed: ${relative_path} does not contain '${expected_text}'"
}

apply_nodejs_patches() {
  if [[ "$ARCH" == "riscv64" ]]; then
    if ! grep -Fq 'fence rw, rw' "${NODEJS_SOURCE_DIR}/deps/uv/src/unix/async.c"; then
      apply_source_patch_once "$NODEJS_SOURCE_DIR" "${PATCH_DIR}/nodejs-libuv-riscv64-clang-fence.patch"
    fi
    verify_source_contains "$NODEJS_SOURCE_DIR" "deps/uv/src/unix/async.c" 'fence rw, rw'
  fi
}

nodejs_archive_url() {
  printf '%s\n' "${NODEJS_ARCHIVE_URL:-https://nodejs.org/dist/v${NODEJS_VERSION}/${NODEJS_ARCHIVE_NAME}}"
}

nodejs_dest_cpu() {
  case "$ARCH" in
    x86_64) printf '%s\n' "x64" ;;
    aarch64) printf '%s\n' "arm64" ;;
    riscv64) printf '%s\n' "riscv64" ;;
    loongarch64) printf '%s\n' "loong64" ;;
    *) die "unsupported Node.js target architecture: ${ARCH}" ;;
  esac
}

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"
  local extra_flags="${3:-}"
  local extra_link_flags="${4:-}"

  render_template "${TEMPLATE_DIR}/clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}" \
    "EXTRA_FLAGS=${extra_flags}" \
    "EXTRA_LINK_FLAGS=${extra_link_flags}"
  chmod +x "$wrapper_path"
}

write_passthrough_compiler_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"
  local extra_flags="${3:-}"
  local extra_link_flags="${4:-}"

  render_template "${TEMPLATE_DIR}/host-clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "EXTRA_FLAGS=${extra_flags}" \
    "EXTRA_LINK_FLAGS=${extra_link_flags}"
  chmod +x "$wrapper_path"
}

write_loongarch64_compat_header() {
  local header_path="$1"

  cat >"$header_path" <<'EOF'
#ifndef DEVELOP_SUIT_NODEJS_LOONGARCH64_COMPAT_H
#define DEVELOP_SUIT_NODEJS_LOONGARCH64_COMPAT_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <sys/mman.h>

#ifdef MAP_TYPE
#undef MAP_TYPE
#endif

#ifndef HWCAP_LOONGARCH_LSX
#define HWCAP_LOONGARCH_LSX 16
#endif

#ifndef HWCAP_LOONGARCH_LASX
#define HWCAP_LOONGARCH_LASX 32
#endif

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 1
#endif

#ifndef DEVELOP_SUIT_NODEJS_HAS_MEMFD_FALLBACK
static inline int develop_suit_memfd_create(const char *name, unsigned int flags) {
#ifdef SYS_memfd_create
  return (int)syscall(SYS_memfd_create, name, flags);
#else
  (void)name;
  (void)flags;
  errno = ENOSYS;
  return -1;
#endif
}
#define DEVELOP_SUIT_NODEJS_HAS_MEMFD_FALLBACK 1
#endif

#ifndef memfd_create
#define memfd_create develop_suit_memfd_create
#endif

#endif
EOF
}

write_linux_compat_headers() {
  local include_dir="$1"
  local compat_header="${include_dir}/nodejs-linux-compat.h"
  local random_header="${include_dir}/sys/random.h"

  mkdir -p "${include_dir}/sys"
  cat >"$compat_header" <<'EOF'
#ifndef DEVELOP_SUIT_NODEJS_LINUX_COMPAT_H
#define DEVELOP_SUIT_NODEJS_LINUX_COMPAT_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <errno.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>

#ifdef MAP_TYPE
#undef MAP_TYPE
#endif

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 1
#endif

#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 2
#endif

#ifndef DEVELOP_SUIT_NODEJS_HAS_MEMFD_FALLBACK
static inline int develop_suit_memfd_create(const char *name, unsigned int flags) {
#ifdef SYS_memfd_create
  return (int)syscall(SYS_memfd_create, name, flags);
#else
  (void)name;
  (void)flags;
  errno = ENOSYS;
  return -1;
#endif
}
#define DEVELOP_SUIT_NODEJS_HAS_MEMFD_FALLBACK 1
#endif

#ifndef memfd_create
#define memfd_create develop_suit_memfd_create
#endif

#endif
EOF

  cat >"$random_header" <<'EOF'
#ifndef DEVELOP_SUIT_NODEJS_SYS_RANDOM_H
#define DEVELOP_SUIT_NODEJS_SYS_RANDOM_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <errno.h>
#include <stddef.h>
#include <unistd.h>
#include <sys/syscall.h>

#ifndef GRND_NONBLOCK
#define GRND_NONBLOCK 0x0001
#endif

#ifndef GRND_RANDOM
#define GRND_RANDOM 0x0002
#endif

#if !defined(SYS_getrandom) && defined(__NR_getrandom)
#define SYS_getrandom __NR_getrandom
#endif

#if !defined(SYS_getrandom)
#  if defined(__x86_64__)
#    define SYS_getrandom 318
#  elif defined(__aarch64__) || defined(__riscv) || defined(__loongarch__)
#    define SYS_getrandom 278
#  endif
#endif

static inline ssize_t develop_suit_getrandom(void *buf, size_t buflen,
                                             unsigned int flags) {
#ifdef SYS_getrandom
  return (ssize_t)syscall(SYS_getrandom, buf, buflen, flags);
#else
  (void)buf;
  (void)buflen;
  (void)flags;
  errno = ENOSYS;
  return -1;
#endif
}

#ifndef getrandom
#define getrandom develop_suit_getrandom
#endif

#endif
EOF
}

remove_static_libraries() {
  find "${SDK_PREFIX}" -type f -name '*.la' -delete
  find "${SDK_PREFIX}" -type f -name '*.a' ! -name '*.dll.a' -delete
}

run_post_install_steps() {
  log "Fixing installed Node.js script shebangs"
  fix_nodejs_script_shebangs

  log "Removing static libraries from Node.js package"
  remove_static_libraries

  log "Copying Linux runtime libraries"
  copy_linux_runtime_libraries

  log "Patching Linux ELF RUNPATH entries"
  patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"

  log "Validating Linux runtime packaging"
  validate_linux_runtime_packaging

  validate_nodejs
}

copy_linux_runtime_libraries() {
  local runtime_dir="${LLVM_ROOT}/lib/${TARGET_TRIPLE}"
  local library_name=""
  local libatomic_dir=""
  local search_roots=()

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  [[ -d "$runtime_dir" ]] || die "missing LLVM C++ runtime directory: ${runtime_dir}"

  for library_name in \
      libc++.so libc++.so.1 libc++.so.1.0 \
      libc++abi.so libc++abi.so.1 libc++abi.so.1.0 \
      libunwind.so libunwind.so.1 libunwind.so.1.0; do
    [[ -e "${runtime_dir}/${library_name}" ]] || die "missing LLVM C++ runtime library: ${runtime_dir}/${library_name}"
    cp -a "${runtime_dir}/${library_name}" "${SDK_PREFIX}/lib/"
  done

  rm -f "${SDK_PREFIX}/lib"/libatomic.so*
  if ! linux_package_needs_library "libatomic.so.1"; then
    return 0
  fi

  search_roots=(
    "$SYSROOT"
    "$LLVM_ROOT"
    /usr/lib
    /usr/lib64
    /lib
    /lib64
  )
  libatomic_dir="$(find_first_library_dir "libatomic.so.1" "${search_roots[@]}")"
  [[ -n "$libatomic_dir" ]] || die "missing target libatomic.so.1 for ${TARGET_TRIPLE}"
  log "Copying libatomic from ${libatomic_dir}"
  cp -a "${libatomic_dir}"/libatomic.so* "${SDK_PREFIX}/lib/"
}

find_first_library_dir() {
  local library_name="$1"
  local root=""
  local library_path=""
  shift

  for root in "$@"; do
    [[ -d "$root" ]] || continue
    library_path="$(
      find "$root" \( -type f -o -type l \) -name "$library_name" -print -quit 2>/dev/null || true
    )"
    if [[ -n "$library_path" ]]; then
      dirname "$library_path"
      return 0
    fi
  done

  return 0
}

linux_package_needs_library() {
  local needed_library="$1"
  local file_path=""
  local needed=""

  [[ "$TARGET_KIND" == "linux" ]] || return 1

  require_command patchelf

  while IFS= read -r -d '' file_path; do
    needed="$(patchelf --print-needed "$file_path" 2>/dev/null || true)"
    if grep -qx "$needed_library" <<<"$needed"; then
      return 0
    fi
  done < <(
    find "${SDK_PREFIX}/bin" "${SDK_PREFIX}/lib" \
      -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) \
      -print0 2>/dev/null
  )

  return 1
}

validate_linux_runtime_packaging() {
  local node_bin="${SDK_PREFIX}/bin/node"
  local rpath=""
  local library_name=""

  [[ "$TARGET_KIND" == "linux" ]] || return 0

  require_command patchelf

  for library_name in \
      libc++.so.1 \
      libc++abi.so.1 \
      libunwind.so.1; do
    [[ -e "${SDK_PREFIX}/lib/${library_name}" ]] || die "missing packaged Linux runtime library: ${SDK_PREFIX}/lib/${library_name}"
  done

  if linux_package_needs_library "libatomic.so.1"; then
    [[ -e "${SDK_PREFIX}/lib/libatomic.so.1" ]] || die "missing packaged Linux runtime library: ${SDK_PREFIX}/lib/libatomic.so.1"
  fi

  rpath="$(patchelf --print-rpath "$node_bin" 2>/dev/null || true)"
  case ":${rpath}:" in
    *':$ORIGIN/../lib:'*) ;;
    *) die "missing Node.js runtime RUNPATH entry: ${node_bin} rpath='${rpath}'" ;;
  esac
}

fix_nodejs_script_shebangs() {
  local script=""
  local first_line=""

  [[ -d "${SDK_PREFIX}/bin" ]] || return 0

  while IFS= read -r -d '' script; do
    IFS= read -r first_line <"$script" || continue
    case "$first_line" in
      '#!'*'/usr/bin/env node'*|'#!'*'/usr/bin/node'*)
        sed -i '1c#!/usr/bin/env node' "$script"
        ;;
    esac
  done < <(
    find "${SDK_PREFIX}/bin" -maxdepth 1 -type f ! -name node -print0 2>/dev/null
  )
}

build_nodejs() {
  local dest_cpu="$1"
  local configure_args=()

  rm -rf "$TARGET_BUILD_DIR"
  mkdir -p "$TARGET_BUILD_DIR"

  configure_args=(
    --prefix="$SDK_PREFIX"
    --cross-compiling
    --dest-os=linux
    --dest-cpu="$dest_cpu"
  )
  if [[ "$ARCH" != "x86_64" ]]; then
    configure_args+=(--openssl-no-asm)
  fi

  log "Configuring Node.js ${NODEJS_VERSION} for ${TARGET_TRIPLE}"
  (
    cd "$NODEJS_SOURCE_DIR"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    env \
      CC="$CC" \
      CXX="$CXX" \
      LD="$CXX" \
      LINK="$CXX" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      CC_host="$BUILD_CC" \
      CXX_host="$BUILD_CXX" \
      LINK_host="$BUILD_CXX" \
      AR_host="${LLVM_ROOT}/bin/llvm-ar" \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CPPFLAGS_host="$COMMON_CPPFLAGS ${CPPFLAGS_host:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      python="${PYTHON:-python3}" \
      ./configure "${configure_args[@]}"

    log "Building Node.js ${NODEJS_VERSION}"
    make -j "$JOBS"
    make install
  )
}

validate_nodejs() {
  local node_bin="${SDK_PREFIX}/bin/node"

  [[ -x "$node_bin" ]] || die "missing Node.js executable: ${node_bin}"
  [[ -d "${SDK_PREFIX}/include/node" ]] || die "missing Node.js headers: ${SDK_PREFIX}/include/node"
  [[ -f "${SDK_PREFIX}/include/node/node.h" ]] || die "missing Node.js header: ${SDK_PREFIX}/include/node/node.h"

  if [[ "$ARCH" == "x86_64" ]]; then
    log "Running x86_64 Node.js smoke test"
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" "$node_bin" - <<'JS'
const assert = require('assert');
assert.strictEqual(process.platform, 'linux');
assert.strictEqual(process.versions.modules.length > 0, true);
require('crypto').createHash('sha256').update('nodejs smoke').digest('hex');
require('zlib').gzipSync(Buffer.from('nodejs smoke'));
console.log('nodejs smoke ok ' + process.version);
JS
  fi
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
NODEJS_VERSION="${NODEJS_VERSION:-24.16.0}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/nodejs-${NODEJS_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
NODEJS_ARCHIVE="${NODEJS_ARCHIVE:-}"
NODEJS_ARCHIVE_NAME="node-v${NODEJS_VERSION}.tar.gz"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ "$TARGET_KIND" == "linux" ]] || die "Node.js package supports Linux targets only"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing package prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make
require_command python3

SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_CC_REAL="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
BUILD_CXX_REAL="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"
TARGET_CC_REAL="${CC:-${LLVM_ROOT}/bin/clang}"
TARGET_CXX_REAL="${CXX:-${LLVM_ROOT}/bin/clang++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"

[[ -x "$BUILD_CC_REAL" ]] || die "missing host C compiler: ${BUILD_CC_REAL}"
[[ -x "$BUILD_CXX_REAL" ]] || die "missing host C++ compiler: ${BUILD_CXX_REAL}"
[[ -x "$TARGET_CC_REAL" ]] || die "missing target C compiler: ${TARGET_CC_REAL}"
[[ -x "$TARGET_CXX_REAL" ]] || die "missing target C++ compiler: ${TARGET_CXX_REAL}"

SOURCE_ROOT="${BUILD_DIR}/src"
NODEJS_SOURCE_DIR="${SOURCE_ROOT}/nodejs"
TARGET_BUILD_DIR="${BUILD_DIR}/build-nodejs"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"

mkdir -p "$SOURCE_ROOT" "$BUILD_TOOLS" "${SDK_PREFIX}/bin" "${SDK_PREFIX}/lib"

COMMON_CPPFLAGS="${COMMON_CPPFLAGS:-}"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="${COMMON_LDFLAGS:-}"
TARGET_COMPILER_EXTRA_FLAGS=""
HOST_COMPILER_EXTRA_FLAGS=""
TARGET_LINKER_EXTRA_FLAGS=""
HOST_LINKER_EXTRA_FLAGS=""
LINUX_COMPAT_INCLUDE_DIR="${BUILD_TOOLS}/compat-include"
write_linux_compat_headers "$LINUX_COMPAT_INCLUDE_DIR"
LINUX_COMPAT_HEADER="${LINUX_COMPAT_INCLUDE_DIR}/nodejs-linux-compat.h"
TARGET_COMPILER_EXTRA_FLAGS="-I${LINUX_COMPAT_INCLUDE_DIR} -include ${LINUX_COMPAT_HEADER}"
HOST_COMPILER_EXTRA_FLAGS="-I${LINUX_COMPAT_INCLUDE_DIR} -include ${LINUX_COMPAT_HEADER}"
TARGET_LINKER_EXTRA_FLAGS="-Wl,--as-needed -Wl,-rpath,\\\$ORIGIN/../lib"
HOST_LINKER_EXTRA_FLAGS="-Wl,--as-needed"
if [[ "$ARCH" == "loongarch64" ]]; then
  LOONGARCH64_COMPAT_HEADER="${BUILD_TOOLS}/nodejs-loongarch64-compat.h"
  write_loongarch64_compat_header "$LOONGARCH64_COMPAT_HEADER"
  TARGET_COMPILER_EXTRA_FLAGS="${TARGET_COMPILER_EXTRA_FLAGS} -include ${LOONGARCH64_COMPAT_HEADER}"
  HOST_COMPILER_EXTRA_FLAGS="${HOST_COMPILER_EXTRA_FLAGS} -include ${LOONGARCH64_COMPAT_HEADER}"
fi
COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,--as-needed -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "$TARGET_CC_REAL" "$TARGET_COMPILER_EXTRA_FLAGS" "$TARGET_LINKER_EXTRA_FLAGS"
write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx" "$TARGET_CXX_REAL" "$TARGET_COMPILER_EXTRA_FLAGS" "$TARGET_LINKER_EXTRA_FLAGS"
write_passthrough_compiler_wrapper "${BUILD_TOOLS}/host-cc" "$BUILD_CC_REAL" "$HOST_COMPILER_EXTRA_FLAGS" "$HOST_LINKER_EXTRA_FLAGS"
write_passthrough_compiler_wrapper "${BUILD_TOOLS}/host-cxx" "$BUILD_CXX_REAL" "$HOST_COMPILER_EXTRA_FLAGS" "$HOST_LINKER_EXTRA_FLAGS"
CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-cc"
CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx"
BUILD_CC="${BUILD_TOOLS}/host-cc"
BUILD_CXX="${BUILD_TOOLS}/host-cxx"

if [[ -z "$NODEJS_ARCHIVE" ]]; then
  download_archive "$(nodejs_archive_url)" "$NODEJS_ARCHIVE_NAME"
  NODEJS_ARCHIVE="${CACHE_DIR}/${NODEJS_ARCHIVE_NAME}"
fi

extract_archive_source "$NODEJS_SOURCE_DIR" "$NODEJS_ARCHIVE" "tools/gyp/pylib/gyp/common.py"
[[ -x "${NODEJS_SOURCE_DIR}/configure" ]] || die "invalid Node.js source tree: missing configure"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"
apply_nodejs_patches

log "Installing Node.js ${NODEJS_VERSION} into ${SDK_PREFIX}"
build_nodejs "$(nodejs_dest_cpu)"
run_post_install_steps

render_template "${TEMPLATE_DIR}/README.nodejs.in" "${SDK_PREFIX}/README.nodejs" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "NODEJS_VERSION=${NODEJS_VERSION}"

log "Node.js package ready: ${SDK_PREFIX}"
