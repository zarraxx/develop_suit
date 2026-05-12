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
  local archive_marker="${source_dir}/.python-source-archive"

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

rewrite_dependency_prefixes() {
  local installed_file=""
  local old_prefix=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.py|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    for old_prefix in \
        "/opt/python_dependencies-${TARGET_TRIPLE}" \
        "/opt/pyhton_dependencies-3-${TARGET_TRIPLE}" \
        "/opt/llvm_dependencies-${TARGET_TRIPLE}"; do
      if grep -IqF "$old_prefix" "$installed_file"; then
        sed -i "s#${old_prefix}#${SDK_PREFIX}#g" "$installed_file"
      fi
    done
  done < <(
    find "$SDK_PREFIX" -type f -print0 2>/dev/null
  )
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete
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

build_host_python() {
  if [[ -x "${HOST_BUILD_DIR}/python" ]]; then
    log "Reusing host Python helper: ${HOST_BUILD_DIR}/python"
    return 0
  fi

  rm -rf "$HOST_BUILD_DIR"
  mkdir -p "$HOST_BUILD_DIR"

  log "Building host Python helper"
  (
    cd "$HOST_BUILD_DIR"
    env \
      CC="$BUILD_CC" \
      CXX="$BUILD_CXX" \
      AR="${LLVM_ROOT}/bin/llvm-ar" \
      RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
      STRIP="${LLVM_ROOT}/bin/llvm-strip" \
      NM="${LLVM_ROOT}/bin/llvm-nm" \
      CPPFLAGS= \
      CFLAGS= \
      CXXFLAGS= \
      LDFLAGS= \
      "${PYTHON_SOURCE_DIR}/configure" \
        --prefix="${BUILD_TOOLS}/host-python" \
        --with-ensurepip=no
    make -j "$JOBS"
  )
}

build_target_python() {
  local configure_build_triple="$CONFIGURE_BUILD_TRIPLE"

  rm -rf "$TARGET_BUILD_DIR"
  mkdir -p "$TARGET_BUILD_DIR"

  render_template "${TEMPLATE_DIR}/python.config.site.in" "$CONFIG_SITE" \
    "AC_CV_BUGGY_GETADDRINFO=no" \
    "AC_CV_FILE_DEV_PTMX=yes" \
    "AC_CV_FILE_DEV_PTC=no"

  log "Configuring Python ${PYTHON_VERSION} for ${TARGET_TRIPLE}"
  (
    cd "$TARGET_BUILD_DIR"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    env \
      CONFIG_SITE="$CONFIG_SITE" \
      HOSTRUNNER="${HOSTRUNNER:-}" \
      PYTHON_FOR_BUILD="${HOST_BUILD_DIR}/python" \
      CC="$CC" \
      CXX="$CXX" \
      LD="$LD" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      OBJCOPY="$OBJCOPY" \
      READELF="$READELF" \
      CC_FOR_BUILD="$BUILD_CC" \
      CXX_FOR_BUILD="$BUILD_CXX" \
      CPP_FOR_BUILD="${BUILD_CC} -E" \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_PATH= \
      PKG_CONFIG_SYSROOT_DIR= \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBUUID_CFLAGS="-I${SDK_PREFIX}/include/uuid" \
      LIBUUID_LIBS="-luuid" \
      LIBSQLITE3_CFLAGS="-I${SDK_PREFIX}/include" \
      LIBSQLITE3_LIBS="-lsqlite3" \
      GDBM_CFLAGS="-I${SDK_PREFIX}/include" \
      GDBM_LIBS="-lgdbm" \
      LIBREADLINE_CFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/ncursesw" \
      LIBREADLINE_LIBS="-lreadline -lncursesw" \
      ZLIB_CFLAGS="-I${SDK_PREFIX}/include" \
      ZLIB_LIBS="-lz" \
      BZIP2_CFLAGS="-I${SDK_PREFIX}/include" \
      BZIP2_LIBS="-lbz2" \
      LIBLZMA_CFLAGS="-I${SDK_PREFIX}/include" \
      LIBLZMA_LIBS="-llzma" \
      LIBZSTD_CFLAGS="-I${SDK_PREFIX}/include" \
      LIBZSTD_LIBS="-lzstd" \
      LIBFFI_CFLAGS="-I${SDK_PREFIX}/include" \
      LIBFFI_LIBS="-lffi" \
      "${PYTHON_SOURCE_DIR}/configure" \
        --build="$configure_build_triple" \
        --host="$TARGET_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        --enable-shared \
        --with-build-python="${HOST_BUILD_DIR}/python" \
        --with-openssl="$SDK_PREFIX" \
        --with-system-expat \
        --with-ensurepip=no

    log "Building Python ${PYTHON_VERSION}"
    make -j "$JOBS"
    make install
  )
}

validate_python() {
  local python_bin="${SDK_PREFIX}/bin/python3.14"

  [[ -x "$python_bin" ]] || die "missing Python executable: ${python_bin}"
  [[ -f "${SDK_PREFIX}/lib/libpython3.14.so" ]] || die "missing libpython3.14.so"

  if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" ]]; then
    log "Running x86_64 Python smoke test"
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" "$python_bin" - <<'PY'
import bz2
import ctypes
import curses
import decimal
import lzma
import readline
import sqlite3
import ssl
import uuid
import xml.parsers.expat
import zlib
try:
    import compression.zstd
except ModuleNotFoundError:
    pass
print("python smoke ok")
PY
  fi
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
PYTHON_VERSION="${PYTHON_VERSION:-3.14.5}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/python-${PYTHON_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
PYTHON_ARCHIVE="${PYTHON_ARCHIVE:-}"
PYTHON_ARCHIVE_NAME="Python-${PYTHON_VERSION}.tar.xz"
PYTHON_ARCHIVE_URL="${PYTHON_ARCHIVE_URL:-https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_ARCHIVE_NAME}}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ "$TARGET_KIND" == "linux" ]] || die "initial packages/python build only supports Linux targets"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing Python dependency prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make
require_command pkg-config

SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TRIPLE="$("${LLVM_ROOT}/bin/clang" -dumpmachine 2>/dev/null || echo x86_64-unknown-linux-gnu)"
CONFIGURE_BUILD_TRIPLE="${CONFIGURE_BUILD_TRIPLE:-$BUILD_TRIPLE}"
if [[ "$CONFIGURE_BUILD_TRIPLE" == "$TARGET_TRIPLE" ]]; then
  CONFIGURE_BUILD_TRIPLE="${ARCH}-buildroot-linux-gnu"
fi

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
BUILD_CXX="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"
CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
LD="${LD:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ld}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy}"
READELF="${READELF:-${LLVM_ROOT}/bin/llvm-readelf}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$LD" ]] || LD="${LLVM_ROOT}/bin/ld.lld"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$OBJCOPY" ]] || OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy"
[[ -x "$READELF" ]] || READELF="${LLVM_ROOT}/bin/llvm-readelf"

SOURCE_ROOT="${BUILD_DIR}/src"
PYTHON_SOURCE_DIR="${SOURCE_ROOT}/python"
HOST_BUILD_DIR="${BUILD_DIR}/build-python"
TARGET_BUILD_DIR="${BUILD_DIR}/target-python"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
CONFIG_SITE="${BUILD_TOOLS}/python-${TARGET_TRIPLE}.config.site"

mkdir -p "$SOURCE_ROOT" "$BUILD_TOOLS"

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "${LLVM_ROOT}/bin/clang"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-cc"
fi
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx" "${LLVM_ROOT}/bin/clang++"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx"
fi

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/uuid -I${SDK_PREFIX}/include/ncursesw"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

rewrite_dependency_prefixes

if [[ -z "$PYTHON_ARCHIVE" ]]; then
  download_archive "$PYTHON_ARCHIVE_URL" "$PYTHON_ARCHIVE_NAME"
  PYTHON_ARCHIVE="${CACHE_DIR}/${PYTHON_ARCHIVE_NAME}"
fi

extract_archive_source "$PYTHON_SOURCE_DIR" "$PYTHON_ARCHIVE" "configure"

log "Installing Python ${PYTHON_VERSION} into ${SDK_PREFIX}"
build_host_python
build_target_python
rewrite_dependency_prefixes
copy_cxx_runtime_libraries
remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_python

render_template "${TEMPLATE_DIR}/README.python.in" "${SDK_PREFIX}/README.python" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "PYTHON_VERSION=${PYTHON_VERSION}"

log "Python package ready: ${SDK_PREFIX}"
