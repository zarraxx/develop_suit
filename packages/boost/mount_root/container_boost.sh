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

boost_archive_name() {
  local version_underscore="${BOOST_VERSION//./_}"
  printf 'boost_%s.tar.bz2\n' "$version_underscore"
}

boost_archive_url() {
  printf 'https://archives.boost.io/release/%s/source/%s\n' "$BOOST_VERSION" "$(boost_archive_name)"
}

extract_archive_source() {
  local source_dir="$1"
  local archive_path="$2"
  local marker_path="$3"
  local archive_name=""
  local archive_marker="${source_dir}/.boost-source-archive"

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

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"

  render_template "${TEMPLATE_DIR}/clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}"
  chmod +x "$wrapper_path"
}

write_user_config() {
  render_template "${TEMPLATE_DIR}/user-config.jam.in" "$USER_CONFIG" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "RANLIB=${RANLIB}" \
    "COMMON_CPPFLAGS=${COMMON_CPPFLAGS}" \
    "COMMON_CXXFLAGS=${COMMON_CXXFLAGS}" \
    "COMMON_LDFLAGS=${COMMON_LDFLAGS}"
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete 2>/dev/null || true
}

copy_cxx_runtime_libraries() {
  local runtime_dir="${LLVM_ROOT}/lib/${TARGET_TRIPLE}"
  local library_name=""

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  [[ -d "$runtime_dir" ]] || die "missing LLVM C++ runtime directory: ${runtime_dir}"

  for library_name in \
      libc++.so libc++.so.1 libc++.so.1.0 \
      libc++abi.so libc++abi.so.1 libc++abi.so.1.0 \
      libunwind.so libunwind.so.1 libunwind.so.1.0; do
    [[ -e "${runtime_dir}/${library_name}" ]] || die "missing LLVM C++ runtime library: ${runtime_dir}/${library_name}"
    cp -a "${runtime_dir}/${library_name}" "${SDK_PREFIX}/lib/"
  done
}

copy_mingw_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  mkdir -p "${SDK_PREFIX}/bin"
  find "${SDK_PREFIX}/lib" \
    \( -type f -name '*.dll' -o -type l -name '*.dll' \) \
    -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
}

build_boost() {
  local b2_args=()

  rm -rf "$BOOST_BUILD_DIR" "$BOOST_STAGE_DIR"
  mkdir -p "$BOOST_BUILD_DIR" "$BOOST_STAGE_DIR"

  log "Bootstrapping Boost.Build ${BOOST_VERSION}"
  (
    cd "$BOOST_SOURCE_DIR"
    env \
      CC="$BUILD_CC" \
      CXX="$BUILD_CXX" \
      ./bootstrap.sh --prefix="$SDK_PREFIX" --with-toolset=clang
  )

  b2_args=(
    --user-config="$USER_CONFIG"
    --prefix="$SDK_PREFIX"
    --build-dir="$BOOST_BUILD_DIR"
    --stagedir="$BOOST_STAGE_DIR"
    --layout=system
    -j "$JOBS"
    toolset=gcc-develop_suit
    target-os="$BOOST_TARGET_OS"
    binary-format="$BOOST_BINARY_FORMAT"
    address-model=64
    variant=release
    link=shared
    runtime-link=shared
    threading=multi
    threadapi="$BOOST_THREAD_API"
    --with-atomic
    --with-chrono
    --with-date_time
    --with-filesystem
    --with-serialization
    --with-system
    --with-thread
    install
  )

  log "Building Boost ${BOOST_VERSION} for ${TARGET_TRIPLE}"
  (
    cd "$BOOST_SOURCE_DIR"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    ./b2 "${b2_args[@]}"
  )
}

validate_boost_library() {
  local library="$1"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}" \
      \( -type f -o -type l \) \
      \( -name "libboost_${library}*.dll" -o -name "boost_${library}*.dll" -o -name "libboost_${library}*.dll.a" \) \
      | grep -q . || die "missing Boost ${library} DLL/import library"
    return 0
  fi

  find "${SDK_PREFIX}/lib" \
    \( -type f -o -type l \) \
    -name "libboost_${library}.so*" \
    | grep -q . || die "missing Boost ${library} shared library"
}

validate_boost() {
  [[ -f "${SDK_PREFIX}/include/boost/version.hpp" ]] || die "missing Boost headers"

  validate_boost_library atomic
  validate_boost_library chrono
  validate_boost_library date_time
  validate_boost_library filesystem
  validate_boost_library serialization
  validate_boost_library system
  validate_boost_library thread
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
BOOST_VERSION="${BOOST_VERSION:-1.84.0}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/boost-${BOOST_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
BOOST_ARCHIVE="${BOOST_ARCHIVE:-}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing Boost package prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    BOOST_TARGET_OS="linux"
    BOOST_BINARY_FORMAT="elf"
    BOOST_THREAD_API="pthread"
    COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-} -fPIC"
    COMMON_LDFLAGS="${COMMON_LDFLAGS:-} -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    BOOST_TARGET_OS="windows"
    BOOST_BINARY_FORMAT="pe"
    BOOST_THREAD_API="win32"
    COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-} -Wno-unused-command-line-argument"
    COMMON_LDFLAGS="${COMMON_LDFLAGS:-}"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
BUILD_CXX="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"

[[ -x "$BUILD_CC" ]] || die "missing build compiler: ${BUILD_CC}"
[[ -x "$BUILD_CXX" ]] || die "missing build C++ compiler: ${BUILD_CXX}"
[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$AR" ]] || die "missing archiver: ${AR}"
[[ -x "$RANLIB" ]] || die "missing ranlib: ${RANLIB}"

SOURCE_ROOT="${BUILD_DIR}/src"
BOOST_SOURCE_DIR="${SOURCE_ROOT}/boost"
BOOST_BUILD_DIR="${BUILD_DIR}/build-boost"
BOOST_STAGE_DIR="${BUILD_DIR}/stage-boost"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
USER_CONFIG="${BUILD_TOOLS}/boost-user-config.jam"

mkdir -p "$SOURCE_ROOT" "$BUILD_TOOLS" "${SDK_PREFIX}/lib"

CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-clang++" "${LLVM_ROOT}/bin/clang++"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-clang++"
fi
[[ -x "$CXX" ]] || die "missing target C++ compiler: ${CXX}"

COMMON_CPPFLAGS="${COMMON_CPPFLAGS:-}"
write_user_config

if [[ -z "$BOOST_ARCHIVE" ]]; then
  BOOST_ARCHIVE_NAME="$(boost_archive_name)"
  download_archive "$(boost_archive_url)" "$BOOST_ARCHIVE_NAME"
  BOOST_ARCHIVE="${CACHE_DIR}/${BOOST_ARCHIVE_NAME}"
fi
[[ -f "$BOOST_ARCHIVE" ]] || die "Boost source archive not found: ${BOOST_ARCHIVE}"

extract_archive_source "$BOOST_SOURCE_DIR" "$BOOST_ARCHIVE" "bootstrap.sh"

log "Installing Boost ${BOOST_VERSION} into ${SDK_PREFIX}"
build_boost
copy_cxx_runtime_libraries
copy_mingw_dlls_to_bin
remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_boost

render_template "${TEMPLATE_DIR}/README.boost.in" "${SDK_PREFIX}/README.boost" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "BOOST_VERSION=${BOOST_VERSION}"

log "Boost package ready: ${SDK_PREFIX}"
