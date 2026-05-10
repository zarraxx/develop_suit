#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
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

write_windres_wrapper() {
  local wrapper_path="$1"
  local real_windres="$2"

  render_template "${TEMPLATE_DIR}/windres-wrapper.in" "$wrapper_path" \
    "REAL_WINDRES=${real_windres}" \
    "SYSROOT=${SYSROOT}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "TARGET_ROOT=${TARGET_ROOT}"
  chmod +x "$wrapper_path"
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
  local archive_name="$2"
  local marker_path="$3"

  if [[ ! -e "${source_dir}/${marker_path}" ]]; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xf "${CACHE_DIR}/${archive_name}" -C "$source_dir" --strip-components=1
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

write_toolchain_file() {
  render_template "${TEMPLATE_DIR}/cmake-toolchain.cmake.in" "$TOOLCHAIN_FILE" \
    "CMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}" \
    "CMAKE_SYSTEM_PROCESSOR=${CMAKE_SYSTEM_PROCESSOR}" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "LD=${LD}" \
    "NM=${NM}" \
    "OBJCOPY=${OBJCOPY}" \
    "RANLIB=${RANLIB}" \
    "STRIP=${STRIP}" \
    "RC=${RC}" \
    "RC_FLAGS=${RC_FLAGS}" \
    "SYSROOT=${SYSROOT}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_ROOT=${TARGET_ROOT}" \
    "LLVM_ROOT=${LLVM_ROOT}"
}

configure_make_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring dependency: ${package_name}"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${PATH}"
    if [[ -n "${tic_path:-}" ]]; then
      export tic_path
    fi
    env \
      CC="$CC" \
      CXX="$CXX" \
      LD="$LD" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      OBJCOPY="$OBJCOPY" \
      OBJDUMP="$OBJDUMP" \
      DLLTOOL="$DLLTOOL" \
      RC="$RC" \
      WINDRES="$RC" \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBS="${LIBS:-}" \
      SHLIB_LIBS="${SHLIB_LIBS:-}" \
      PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR= \
      "${source_dir}/configure" \
        --build="$CONFIGURE_BUILD_TRIPLE" \
        --host="$CONFIGURE_HOST_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        "$@"
    make -j "$JOBS"
    make install
  )
}

cmake_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring dependency: ${package_name}"
  cmake -S "$source_dir" -B "$package_build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
    "$@"

  log "Building dependency: ${package_name}"
  cmake --build "$package_build_dir" --parallel "$JOBS"
  cmake --install "$package_build_dir"
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete
}

require_path() {
  local path="$1"
  [[ -e "$path" ]] || die "missing required dependency artifact: $path"
}

require_glob() {
  local pattern="$1"
  compgen -G "$pattern" >/dev/null || die "missing required dependency artifact: $pattern"
}

first_glob() {
  local pattern="$1"
  local path=""

  path="$(compgen -G "$pattern" | sort | head -n 1 || true)"
  [[ -n "$path" ]] || die "missing required dependency artifact: $pattern"
  printf '%s\n' "$path"
}

validate_dynamic_libraries() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    require_path "${SDK_PREFIX}/bin/libz.dll"
    require_path "${SDK_PREFIX}/bin/libzstd.dll"
    require_path "${SDK_PREFIX}/bin/liblz4.dll"
    require_path "${SDK_PREFIX}/bin/libbz2-1.dll"
    require_path "${SDK_PREFIX}/bin/liblzma.dll"
    require_glob "${SDK_PREFIX}/bin/libiconv*.dll"
    require_glob "${SDK_PREFIX}/bin/libcharset*.dll"
    require_glob "${SDK_PREFIX}/bin/libxml2*.dll"
    require_glob "${SDK_PREFIX}/bin/libpcre2-8*.dll"
    require_glob "${SDK_PREFIX}/bin/libpcre2-16*.dll"
    require_glob "${SDK_PREFIX}/bin/libpcre2-32*.dll"
    require_glob "${SDK_PREFIX}/bin/libpcre2-posix*.dll"
    require_glob "${SDK_PREFIX}/bin/libncursesw*.dll"
    require_glob "${SDK_PREFIX}/bin/libreadline*.dll"
    require_glob "${SDK_PREFIX}/bin/libhistory*.dll"
    require_glob "${SDK_PREFIX}/bin/libffi*.dll"
    require_glob "${SDK_PREFIX}/bin/libintl*.dll"
    require_glob "${SDK_PREFIX}/bin/libssl*.dll"
    require_glob "${SDK_PREFIX}/bin/libcrypto*.dll"

    require_path "${SDK_PREFIX}/lib/libz.dll.a"
    require_path "${SDK_PREFIX}/lib/libzstd.dll.a"
    require_path "${SDK_PREFIX}/lib/liblz4.dll.a"
    require_path "${SDK_PREFIX}/lib/libbz2.dll.a"
    require_path "${SDK_PREFIX}/lib/liblzma.dll.a"
    require_glob "${SDK_PREFIX}/lib/libiconv*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libcharset*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libxml2*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libpcre2-8*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libpcre2-16*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libpcre2-32*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libpcre2-posix*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libncursesw*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libreadline*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libhistory*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libffi*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libintl*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libssl*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libcrypto*.dll.a"
  else
    require_path "${SDK_PREFIX}/lib/libz.so"
    require_path "${SDK_PREFIX}/lib/libzstd.so"
    require_path "${SDK_PREFIX}/lib/liblz4.so"
    require_path "${SDK_PREFIX}/lib/libbz2.so"
    require_path "${SDK_PREFIX}/lib/liblzma.so"
    require_path "${SDK_PREFIX}/lib/libiconv.so"
    require_path "${SDK_PREFIX}/lib/libcharset.so"
    require_path "${SDK_PREFIX}/lib/libxml2.so"
    require_path "${SDK_PREFIX}/lib/libpcre2-8.so"
    require_path "${SDK_PREFIX}/lib/libpcre2-16.so"
    require_path "${SDK_PREFIX}/lib/libpcre2-32.so"
    require_path "${SDK_PREFIX}/lib/libpcre2-posix.so"
    require_path "${SDK_PREFIX}/lib/libncursesw.so"
    require_path "${SDK_PREFIX}/lib/libtinfo.so"
    require_path "${SDK_PREFIX}/lib/libreadline.so"
    require_path "${SDK_PREFIX}/lib/libhistory.so"
    require_path "${SDK_PREFIX}/lib/libffi.so"
    require_path "${SDK_PREFIX}/lib/libintl.so"
    require_path "${SDK_PREFIX}/lib/libssl.so"
    require_path "${SDK_PREFIX}/lib/libcrypto.so"
  fi
}

build_host_ncurses_tic() {
  local source_dir="$1"
  local host_prefix="${BUILD_TOOLS}/host-ncurses"
  local package_build_dir="${DEP_BUILD_DIR}/ncurses-host-tic"

  rm -rf "$package_build_dir" "$host_prefix"
  mkdir -p "$package_build_dir" "$host_prefix"

  log "Building host tic for cross ncurses terminfo install"
  (
    cd "$package_build_dir"
    env \
      CC="${BUILD_CC:-clang}" \
      CXX="${BUILD_CXX:-clang++}" \
      CPPFLAGS= \
      CFLAGS= \
      CXXFLAGS= \
      LDFLAGS= \
      LIBS= \
      "${source_dir}/configure" \
        --build="$BUILD_TRIPLE" \
        --host="$BUILD_TRIPLE" \
        --prefix="$host_prefix" \
        --without-shared \
        --with-normal \
        --without-cxx \
        --without-cxx-binding \
        --without-ada \
        --without-manpages \
        --without-tests \
        --without-debug \
        --enable-widec \
        --with-progs \
        --disable-db-install
    make -j "$JOBS"
    mkdir -p "${host_prefix}/bin"
    /usr/bin/install -c -m 755 progs/tic "${host_prefix}/bin/tic"
  )

  [[ -x "${host_prefix}/bin/tic" ]] || die "failed to build host tic"
}

write_linux_ncurses_linker_script() {
  local library_name="$1"
  local dependency="$2"
  local soname="${library_name}.so.6"

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  [[ -e "${SDK_PREFIX}/lib/${library_name}.so" ]] || return 0
  if [[ ! -e "${SDK_PREFIX}/lib/${soname}" ]]; then
    soname="$(basename "$(readlink -f "${SDK_PREFIX}/lib/${library_name}.so")")"
  fi
  [[ -n "$soname" && "$soname" != "${library_name}.so" ]] || return 0

  rm -f "${SDK_PREFIX}/lib/${library_name}.so"
  printf 'INPUT(%s -l%s)\n' "$soname" "$dependency" >"${SDK_PREFIX}/lib/${library_name}.so"
}

openssl_target_for_target() {
  case "$TARGET_KIND:$ARCH" in
    linux:x86_64)
      echo "linux-x86_64"
      ;;
    linux:aarch64)
      echo "linux-aarch64"
      ;;
    linux:riscv64)
      echo "linux64-riscv64"
      ;;
    linux:loongarch64)
      echo "linux64-loongarch64"
      ;;
    mingw:x86_64)
      echo "mingw64"
      ;;
    *)
      die "unsupported OpenSSL target: ${TARGET_KIND}:${ARCH}"
      ;;
  esac
}

build_openssl() {
  local source_dir="$1"
  local package_build_dir="${DEP_BUILD_DIR}/openssl"
  local openssl_target=""
  local openssl_ldflags="$COMMON_LDFLAGS"

  openssl_target="$(openssl_target_for_target)"
  if [[ "$TARGET_KIND" == "linux" ]]; then
    openssl_ldflags="${openssl_ldflags} -Wl,--undefined-version"
  fi

  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"
  cp -a "${source_dir}/." "$package_build_dir/"

  log "Configuring dependency: openssl"
  log "OpenSSL target: ${openssl_target}"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${PATH}"
    env \
      CC="$CC" \
      CXX="$CXX" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      WINDRES="$RC" \
      RC="$RC" \
      CPPFLAGS="$COMMON_CPPFLAGS" \
      CFLAGS="$COMMON_CFLAGS" \
      CXXFLAGS="$COMMON_CXXFLAGS" \
      LDFLAGS="$openssl_ldflags" \
      perl ./Configure \
        "$openssl_target" \
        --prefix="$SDK_PREFIX" \
        --libdir=lib \
        --openssldir=/etc/ssl \
        --with-zlib-include="$SDK_PREFIX/include" \
        --with-zlib-lib="$SDK_PREFIX/lib" \
        shared \
        zlib \
        no-tests
    make -j "$JOBS"
    make install_sw
  )
}

build_bzip2() {
  local source_dir="$1"
  local package_build_dir="${DEP_BUILD_DIR}/bzip2"
  local objects=(
    blocksort
    huffman
    crctable
    randtable
    compress
    decompress
    bzlib
  )
  local object=""

  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"
  cp -a "${source_dir}/." "$package_build_dir/"

  log "Building dependency: bzip2"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${PATH}"

    if [[ "$TARGET_KIND" == "mingw" ]]; then
      for object in "${objects[@]}"; do
        "$CC" $COMMON_CPPFLAGS $COMMON_CFLAGS -D_FILE_OFFSET_BITS=64 \
          -c "${object}.c" -o "${object}.o"
      done
      "$CC" -shared -o libbz2-1.dll \
        $COMMON_LDFLAGS \
        -Wl,--out-implib,libbz2.dll.a \
        -Wl,--export-all-symbols \
        "${objects[@]/%/.o}"
    else
      for object in "${objects[@]}"; do
        "$CC" $COMMON_CPPFLAGS $COMMON_CFLAGS -D_FILE_OFFSET_BITS=64 -fPIC \
          -c "${object}.c" -o "${object}.pic.o"
      done
      "$CC" -shared -o libbz2.so.1.0.8 \
        $COMMON_LDFLAGS \
        -Wl,-soname,libbz2.so.1.0 \
        "${objects[@]/%/.pic.o}"
      ln -sf libbz2.so.1.0.8 libbz2.so.1.0
      ln -sf libbz2.so.1.0.8 libbz2.so.1
      ln -sf libbz2.so.1.0.8 libbz2.so
    fi

    "$CC" $COMMON_CPPFLAGS $COMMON_CFLAGS -D_FILE_OFFSET_BITS=64 \
      -c bzip2.c -o bzip2.o
    "$CC" $COMMON_CFLAGS $COMMON_LDFLAGS -L. -o "bzip2${EXEEXT}" bzip2.o -lbz2
    "$CC" $COMMON_CPPFLAGS $COMMON_CFLAGS -D_FILE_OFFSET_BITS=64 \
      -c bzip2recover.c -o bzip2recover.o
    "$CC" $COMMON_CFLAGS -o "bzip2recover${EXEEXT}" bzip2recover.o

    /usr/bin/install -d "${SDK_PREFIX}/bin" "${SDK_PREFIX}/include" "${SDK_PREFIX}/lib/pkgconfig"
    /usr/bin/install -m 0755 "bzip2${EXEEXT}" "${SDK_PREFIX}/bin/bzip2${EXEEXT}"
    /usr/bin/install -m 0755 "bzip2recover${EXEEXT}" "${SDK_PREFIX}/bin/bzip2recover${EXEEXT}"
    if [[ "$TARGET_KIND" == "mingw" ]]; then
      cp -f "bzip2${EXEEXT}" "${SDK_PREFIX}/bin/bunzip2${EXEEXT}"
      cp -f "bzip2${EXEEXT}" "${SDK_PREFIX}/bin/bzcat${EXEEXT}"
      /usr/bin/install -m 0755 libbz2-1.dll "${SDK_PREFIX}/bin/libbz2-1.dll"
      /usr/bin/install -m 0644 libbz2.dll.a "${SDK_PREFIX}/lib/libbz2.dll.a"
    else
      ln -sf bzip2 "${SDK_PREFIX}/bin/bunzip2"
      ln -sf bzip2 "${SDK_PREFIX}/bin/bzcat"
      cp -a libbz2.so libbz2.so.1 libbz2.so.1.0 libbz2.so.1.0.8 "${SDK_PREFIX}/lib/"
    fi
    /usr/bin/install -m 0644 bzlib.h "${SDK_PREFIX}/include/bzlib.h"
  )

  render_template "${TEMPLATE_DIR}/bzip2.pc.in" "${SDK_PREFIX}/lib/pkgconfig/bzip2.pc" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "BZIP2_VERSION=${BZIP2_VERSION}"
}

copy_dependency_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \;
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
ZSTD_VERSION="${ZSTD_VERSION:-1.5.7}"
LZ4_VERSION="${LZ4_VERSION:-1.10.0}"
BZIP2_VERSION="${BZIP2_VERSION:-1.0.8}"
XZ_VERSION="${XZ_VERSION:-5.8.1}"
LIBICONV_VERSION="${LIBICONV_VERSION:-1.19}"
LIBXML2_VERSION="${LIBXML2_VERSION:-2.15.3}"
PCRE2_VERSION="${PCRE2_VERSION:-10.47}"
NCURSES_VERSION="${NCURSES_VERSION:-6.6}"
READLINE_VERSION="${READLINE_VERSION:-8.3}"
LIBFFI_VERSION="${LIBFFI_VERSION:-3.5.2}"
GETTEXT_VERSION="${GETTEXT_VERSION:-1.0}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.20}"

ZLIB_ARCHIVE_NAME="zlib-${ZLIB_VERSION}.tar.gz"
ZSTD_ARCHIVE_NAME="zstd-${ZSTD_VERSION}.tar.gz"
LZ4_ARCHIVE_NAME="lz4-${LZ4_VERSION}.tar.gz"
BZIP2_ARCHIVE_NAME="bzip2-${BZIP2_VERSION}.tar.gz"
XZ_ARCHIVE_NAME="xz-${XZ_VERSION}.tar.xz"
LIBICONV_ARCHIVE_NAME="libiconv-${LIBICONV_VERSION}.tar.gz"
LIBXML2_ARCHIVE_NAME="libxml2-v${LIBXML2_VERSION}.tar.bz2"
PCRE2_ARCHIVE_NAME="pcre2-${PCRE2_VERSION}.tar.gz"
NCURSES_ARCHIVE_NAME="ncurses-${NCURSES_VERSION}.tar.gz"
READLINE_ARCHIVE_NAME="readline-${READLINE_VERSION}.tar.gz"
LIBFFI_ARCHIVE_NAME="libffi-${LIBFFI_VERSION}.tar.gz"
GETTEXT_ARCHIVE_NAME="gettext-${GETTEXT_VERSION}.tar.gz"
OPENSSL_ARCHIVE_NAME="openssl-${OPENSSL_VERSION}.tar.gz"

ZLIB_ARCHIVE_URL="${ZLIB_ARCHIVE_URL:-https://zlib.net/${ZLIB_ARCHIVE_NAME}}"
ZSTD_ARCHIVE_URL="${ZSTD_ARCHIVE_URL:-https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/${ZSTD_ARCHIVE_NAME}}"
LZ4_ARCHIVE_URL="${LZ4_ARCHIVE_URL:-https://github.com/lz4/lz4/releases/download/v${LZ4_VERSION}/${LZ4_ARCHIVE_NAME}}"
BZIP2_ARCHIVE_URL="${BZIP2_ARCHIVE_URL:-https://sourceware.org/pub/bzip2/${BZIP2_ARCHIVE_NAME}}"
XZ_ARCHIVE_URL="${XZ_ARCHIVE_URL:-https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/${XZ_ARCHIVE_NAME}}"
LIBICONV_ARCHIVE_URL="${LIBICONV_ARCHIVE_URL:-https://ftp.gnu.org/pub/gnu/libiconv/${LIBICONV_ARCHIVE_NAME}}"
LIBXML2_ARCHIVE_URL="${LIBXML2_ARCHIVE_URL:-https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML2_VERSION}/${LIBXML2_ARCHIVE_NAME}}"
PCRE2_ARCHIVE_URL="${PCRE2_ARCHIVE_URL:-https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/${PCRE2_ARCHIVE_NAME}}"
NCURSES_ARCHIVE_URL="${NCURSES_ARCHIVE_URL:-https://ftp.gnu.org/gnu/ncurses/${NCURSES_ARCHIVE_NAME}}"
READLINE_ARCHIVE_URL="${READLINE_ARCHIVE_URL:-https://ftp.gnu.org/gnu/readline/${READLINE_ARCHIVE_NAME}}"
LIBFFI_ARCHIVE_URL="${LIBFFI_ARCHIVE_URL:-https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/${LIBFFI_ARCHIVE_NAME}}"
GETTEXT_ARCHIVE_URL="${GETTEXT_ARCHIVE_URL:-https://ftp.gnu.org/pub/gnu/gettext/${GETTEXT_ARCHIVE_NAME}}"
OPENSSL_ARCHIVE_URL="${OPENSSL_ARCHIVE_URL:-https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OPENSSL_ARCHIVE_NAME}}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"

require_command curl
require_command tar
require_command make
require_command cmake
require_command ninja
require_command perl

case "$TARGET_KIND" in
  linux)
    CMAKE_SYSTEM_NAME="Linux"
    CMAKE_SYSTEM_PROCESSOR="$ARCH"
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    EXEEXT=""
    ;;
  mingw)
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-x86_64-w64-mingw32}"
    EXEEXT=".exe"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac

[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TRIPLE="$("${LLVM_ROOT}/bin/clang" -dumpmachine 2>/dev/null || echo x86_64-unknown-linux-gnu)"
CONFIGURE_BUILD_TRIPLE="${CONFIGURE_BUILD_TRIPLE:-$BUILD_TRIPLE}"
if [[ "$CONFIGURE_BUILD_TRIPLE" == "$CONFIGURE_HOST_TRIPLE" ]]; then
  CONFIGURE_BUILD_TRIPLE="${ARCH}-llvmsdkbuild-linux-gnu"
fi

CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
LD="${LD:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ld}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy}"
RC="${RC:-${LLVM_ROOT}/bin/llvm-windres}"
OBJDUMP="${OBJDUMP:-${LLVM_ROOT}/bin/llvm-objdump}"
DLLTOOL="${DLLTOOL:-${LLVM_ROOT}/bin/llvm-dlltool}"

if [[ ! -x "$CC" ]]; then
  CC="${LLVM_ROOT}/bin/clang --target=${TARGET_TRIPLE} --sysroot=${SYSROOT}"
fi
if [[ ! -x "$CXX" ]]; then
  CXX="${LLVM_ROOT}/bin/clang++ --target=${TARGET_TRIPLE} --sysroot=${SYSROOT}"
fi
[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$LD" ]] || LD="${LLVM_ROOT}/bin/ld.lld"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$OBJCOPY" ]] || OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy"
[[ -x "$RC" ]] || RC="${LLVM_ROOT}/bin/llvm-rc"
[[ -x "$OBJDUMP" ]] || OBJDUMP="${LLVM_ROOT}/bin/llvm-objdump"
[[ -x "$DLLTOOL" ]] || DLLTOOL="${LLVM_ROOT}/bin/llvm-dlltool"

DEP_SOURCE_DIR="${BUILD_DIR}/deps-source"
DEP_BUILD_DIR="${BUILD_DIR}/deps-build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TOOLCHAIN_FILE="${BUILD_DIR}/llvmsdk-deps-toolchain.cmake"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"

mkdir -p "$SDK_PREFIX" "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS"

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "${LLVM_ROOT}/bin/clang"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-cc"
fi
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx" "${LLVM_ROOT}/bin/clang++"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx"
fi
if [[ "$TARGET_KIND" == "mingw" ]]; then
  write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "$RC"
  RC="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
  render_template "${TEMPLATE_DIR}/strip.in" "${BUILD_TOOLS}/strip" \
    "STRIP=${STRIP}"
  chmod +x "${BUILD_TOOLS}/strip"
fi

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/ncursesw"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi
RC_FLAGS="${RC_FLAGS:-}"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  RC_FLAGS="-I${SYSROOT}/usr/${TARGET_TRIPLE}/include -I${TARGET_ROOT}/include ${RC_FLAGS}"
fi

write_toolchain_file

download_archive "$ZLIB_ARCHIVE_URL" "$ZLIB_ARCHIVE_NAME"
download_archive "$ZSTD_ARCHIVE_URL" "$ZSTD_ARCHIVE_NAME"
download_archive "$LZ4_ARCHIVE_URL" "$LZ4_ARCHIVE_NAME"
download_archive "$BZIP2_ARCHIVE_URL" "$BZIP2_ARCHIVE_NAME"
download_archive "$XZ_ARCHIVE_URL" "$XZ_ARCHIVE_NAME"
download_archive "$LIBICONV_ARCHIVE_URL" "$LIBICONV_ARCHIVE_NAME"
download_archive "$LIBXML2_ARCHIVE_URL" "$LIBXML2_ARCHIVE_NAME"
download_archive "$PCRE2_ARCHIVE_URL" "$PCRE2_ARCHIVE_NAME"
download_archive "$NCURSES_ARCHIVE_URL" "$NCURSES_ARCHIVE_NAME"
download_archive "$READLINE_ARCHIVE_URL" "$READLINE_ARCHIVE_NAME"
download_archive "$LIBFFI_ARCHIVE_URL" "$LIBFFI_ARCHIVE_NAME"
download_archive "$GETTEXT_ARCHIVE_URL" "$GETTEXT_ARCHIVE_NAME"
download_archive "$OPENSSL_ARCHIVE_URL" "$OPENSSL_ARCHIVE_NAME"

extract_archive_source "${DEP_SOURCE_DIR}/zlib" "$ZLIB_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/zstd" "$ZSTD_ARCHIVE_NAME" "build/cmake/CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/lz4" "$LZ4_ARCHIVE_NAME" "build/cmake/CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/bzip2" "$BZIP2_ARCHIVE_NAME" "Makefile"
extract_archive_source "${DEP_SOURCE_DIR}/xz" "$XZ_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libiconv" "$LIBICONV_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libxml2" "$LIBXML2_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/pcre2" "$PCRE2_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/ncurses" "$NCURSES_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/readline" "$READLINE_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libffi" "$LIBFFI_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/gettext" "$GETTEXT_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/openssl" "$OPENSSL_ARCHIVE_NAME" "Configure"

if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/readline/.llvmsdk-msys2-no-winsize.patch.applied" ]]; then
  log "Applying readline MSYS2 no-winsize patch"
  (
    cd "${DEP_SOURCE_DIR}/readline"
    patch -p1 -i /work/mount_root/patch/readline-msys2-no-winsize.patch
    touch .llvmsdk-msys2-no-winsize.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/readline/.llvmsdk-msys2-export-all-symbols.patch.applied" ]]; then
  log "Applying readline MSYS2 export-all-symbols patch"
  (
    cd "${DEP_SOURCE_DIR}/readline"
    patch -p1 -i /work/mount_root/patch/readline-msys2-export-all-symbols.patch
    touch .llvmsdk-msys2-export-all-symbols.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/bzip2/.llvmsdk-mingw-cdecl.patch.applied" ]]; then
  log "Applying bzip2 MinGW cdecl patch"
  (
    cd "${DEP_SOURCE_DIR}/bzip2"
    patch -p1 -i /work/mount_root/patch/bzip2-mingw-cdecl.patch
    touch .llvmsdk-mingw-cdecl.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/libiconv/.llvmsdk-libtool-mingw-lld-shared.patch.applied" ]]; then
  log "Applying libiconv MinGW lld shared-library patch"
  (
    cd "${DEP_SOURCE_DIR}/libiconv"
    patch -p0 -i /work/mount_root/patch/libtool-mingw-lld-shared.patch
    touch .llvmsdk-libtool-mingw-lld-shared.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/libiconv/libcharset/.llvmsdk-libtool-mingw-lld-shared.patch.applied" ]]; then
  log "Applying libcharset MinGW lld shared-library patch"
  (
    cd "${DEP_SOURCE_DIR}/libiconv/libcharset"
    patch -p0 -i /work/mount_root/patch/libtool-mingw-lld-shared.patch
    touch .llvmsdk-libtool-mingw-lld-shared.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/libffi/.llvmsdk-libtool-mingw-lld-shared.patch.applied" ]]; then
  log "Applying libffi MinGW lld shared-library patch"
  (
    cd "${DEP_SOURCE_DIR}/libffi"
    patch -p0 -i /work/mount_root/patch/libtool-mingw-lld-shared.patch
    touch .llvmsdk-libtool-mingw-lld-shared.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/gettext/gettext-runtime/intl/.llvmsdk-libtool-mingw-lld-shared.patch.applied" ]]; then
  log "Applying gettext intl MinGW lld shared-library patch"
  (
    cd "${DEP_SOURCE_DIR}/gettext/gettext-runtime/intl"
    patch -p0 -i /work/mount_root/patch/libtool-mingw-lld-shared.patch
    touch .llvmsdk-libtool-mingw-lld-shared.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/gettext/gettext-runtime/libasprintf/.llvmsdk-libtool-mingw-lld-shared.patch.applied" ]]; then
  log "Applying gettext libasprintf MinGW lld shared-library patch"
  (
    cd "${DEP_SOURCE_DIR}/gettext/gettext-runtime/libasprintf"
    patch -p0 -i /work/mount_root/patch/libtool-mingw-lld-shared.patch
    touch .llvmsdk-libtool-mingw-lld-shared.patch.applied
  )
fi
if [[ "$TARGET_KIND" == "mingw" && ! -e "${DEP_SOURCE_DIR}/gettext/gettext-runtime/.llvmsdk-libtool-mingw-lld-shared.patch.applied" ]]; then
  log "Applying gettext MinGW lld shared-library patch"
  (
    cd "${DEP_SOURCE_DIR}/gettext/gettext-runtime"
    patch -p0 -i /work/mount_root/patch/libtool-mingw-lld-shared.patch
    touch .llvmsdk-libtool-mingw-lld-shared.patch.applied
  )
fi

log "Installing LLVM SDK dependencies into ${SDK_PREFIX}"

cmake_install zlib "${DEP_SOURCE_DIR}/zlib" \
  -DZLIB_BUILD_SHARED=ON \
  -DZLIB_BUILD_STATIC=OFF \
  -DBUILD_SHARED_LIBS=ON \
  -DZLIB_BUILD_TESTING=OFF \
  -DZLIB_BUILD_MINIZIP=OFF \
  -DZLIB_INSTALL=ON

cmake_install zstd "${DEP_SOURCE_DIR}/zstd/build/cmake" \
  -DZSTD_BUILD_SHARED=ON \
  -DZSTD_BUILD_STATIC=OFF \
  -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_BUILD_TESTS=OFF \
  -DZSTD_BUILD_CONTRIB=OFF \
  -DZSTD_MULTITHREAD_SUPPORT=ON \
  -DZSTD_LEGACY_SUPPORT=OFF

cmake_install lz4 "${DEP_SOURCE_DIR}/lz4/build/cmake" \
  -DBUILD_SHARED_LIBS=ON \
  -DLZ4_BUILD_CLI=OFF \
  -DLZ4_BUILD_LEGACY_LZ4C=OFF

build_bzip2 "${DEP_SOURCE_DIR}/bzip2"

cmake_install xz "${DEP_SOURCE_DIR}/xz" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DXZ_DOC=OFF \
  -DXZ_NLS=OFF \
  -DXZ_TOOL_LZMADEC=OFF \
  -DXZ_TOOL_LZMAINFO=OFF \
  -DXZ_TOOL_SCRIPTS=OFF \
  -DXZ_TOOL_XZ=OFF \
  -DXZ_TOOL_XZDEC=OFF

configure_make_install libiconv "${DEP_SOURCE_DIR}/libiconv" \
  --enable-shared \
  --disable-static

if [[ "$TARGET_KIND" == "mingw" ]]; then
  ICONV_LIBRARY="$(first_glob "${SDK_PREFIX}/lib/libiconv*.dll.a")"
else
  ICONV_LIBRARY="${SDK_PREFIX}/lib/libiconv.so"
fi
require_path "$ICONV_LIBRARY"

build_openssl "${DEP_SOURCE_DIR}/openssl"

cmake_install libxml2 "${DEP_SOURCE_DIR}/libxml2" \
  "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
  -DBUILD_SHARED_LIBS=ON \
  -DLIBXML2_WITH_ICONV=ON \
  -DLIBXML2_WITH_ICU=OFF \
  -DLIBXML2_WITH_LZMA=ON \
  -DLIBXML2_WITH_MODULES=OFF \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_ZLIB=ON \
  "-DIconv_INCLUDE_DIR=${SDK_PREFIX}/include" \
  "-DIconv_LIBRARY=${ICONV_LIBRARY}"

cmake_install pcre2 "${DEP_SOURCE_DIR}/pcre2" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DPCRE2_BUILD_PCRE2_8=ON \
  -DPCRE2_BUILD_PCRE2_16=ON \
  -DPCRE2_BUILD_PCRE2_32=ON \
  -DPCRE2_BUILD_TESTS=OFF \
  -DPCRE2_BUILD_PCRE2GREP=OFF \
  -DPCRE2_SUPPORT_JIT=ON \
  -DPCRE2_SUPPORT_UNICODE=ON

if [[ "$TARGET_KIND" == "mingw" ]]; then
  build_host_ncurses_tic "${DEP_SOURCE_DIR}/ncurses"

  cf_cv_func_nanosleep=no \
  tic_path="${BUILD_TOOLS}/host-ncurses/bin/tic" \
  CFLAGS="${CFLAGS:-} -D__USE_MINGW_ACCESS" \
  configure_make_install ncurses "${DEP_SOURCE_DIR}/ncurses" \
    "--program-prefix=${CONFIGURE_HOST_TRIPLE}-" \
    "--mandir=${SDK_PREFIX}/share/man" \
    --with-cxx \
    --with-cxx-shared \
    --with-shared \
    --without-normal \
    --with-pcre2 \
    --without-ada \
    --without-debug \
    --without-pthread \
    --enable-assertions \
    --enable-colorfgbg \
    --enable-database \
    --enable-ext-colors \
    --enable-ext-mouse \
    --enable-interop \
    --enable-sp-funcs \
    --enable-term-driver \
    --enable-widec \
    --enable-pc-files \
    --disable-stripping \
    --disable-home-terminfo \
    --disable-rpath \
    --disable-symlinks \
    "--with-tic-path=${BUILD_TOOLS}/host-ncurses/bin/tic" \
    "--with-pkg-config-libdir=${SDK_PREFIX}/lib/pkgconfig"

  rm -f "${SDK_PREFIX}/include/ncursesw/nc_win32.h"
  if [[ -d "${SDK_PREFIX}/include/ncursesw" && ! -d "${SDK_PREFIX}/include/ncurses" ]]; then
    cp -a "${SDK_PREFIX}/include/ncursesw" "${SDK_PREFIX}/include/ncurses"
  fi
  if [[ -f "${SDK_PREFIX}/lib/libncursesw.a" && ! -f "${SDK_PREFIX}/lib/libncurses.a" ]]; then
    cp -a "${SDK_PREFIX}/lib/libncursesw.a" "${SDK_PREFIX}/lib/libncurses.a"
  fi
else
  build_host_ncurses_tic "${DEP_SOURCE_DIR}/ncurses"

  cf_cv_type_of_bool="unsigned char" \
  cf_cv_working_poll=yes \
  tic_path="${BUILD_TOOLS}/host-ncurses/bin/tic" \
  LDFLAGS="${LDFLAGS:-} -Wl,--undefined-version" \
  configure_make_install ncurses "${DEP_SOURCE_DIR}/ncurses" \
    --with-shared \
    --without-normal \
    --without-profile \
    --without-debug \
    --with-cxx \
    --with-cxx-shared \
    --without-ada \
    --without-manpages \
    --without-tests \
    --without-progs \
    --enable-echo \
    --enable-const \
    --enable-symlinks \
    --enable-widec \
    --enable-overwrite \
    --disable-rpath \
    --disable-stripping \
    --disable-setuid-environ \
    --disable-root-access \
    --disable-termcap \
    --disable-relink \
    --disable-pkg-ldflags \
    --disable-wattr-macros \
    --with-termlib=tinfo \
    --with-ticlib=tic \
    --with-default-terminfo-dir=/etc/terminfo \
    "--with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo" \
    --with-xterm-kbs=del \
    --with-versioned-syms \
    --enable-pc-files \
    "--with-tic-path=${BUILD_TOOLS}/host-ncurses/bin/tic" \
    "--with-pkg-config-libdir=${SDK_PREFIX}/lib/pkgconfig"
fi

if [[ "$TARGET_KIND" == "linux" ]]; then
  (
    cd "${SDK_PREFIX}/lib"
    write_linux_ncurses_linker_script libncursesw tinfo
    if [[ -e libtinfow.so && ! -e libtinfo.so ]]; then
      ln -sf libtinfow.so libtinfo.so
    fi
    if [[ -e libtinfow.a && ! -e libtinfo.a ]]; then
      ln -sf libtinfow.a libtinfo.a
    fi
    if [[ -e libncursesw.so.6 ]]; then
      printf 'INPUT(libncursesw.so.6 -ltinfo)\n' >libncurses.so
    elif [[ -e libncursesw.so ]]; then
      printf 'INPUT(libncursesw.so -ltinfo)\n' >libncurses.so
    fi
    if [[ -e libncursesw.a && ! -e libncurses.a ]]; then
      ln -sf libncursesw.a libncurses.a
    fi
    if [[ -e libncursesw.so.6 ]]; then
      printf 'INPUT(libncursesw.so.6 -ltinfo)\n' >libcurses.so
    elif [[ -e libncursesw.so ]]; then
      printf 'INPUT(libncursesw.so -ltinfo)\n' >libcurses.so
    fi
    if [[ -e libncursesw.a && ! -e libcurses.a ]]; then
      ln -sf libncursesw.a libcurses.a
    fi
    if [[ -e libtinfow.so ]]; then
      ln -sf libtinfow.so libtermcap.so
    fi
    if [[ -e libtinfow.a ]]; then
      ln -sf libtinfow.a libtermcap.a
    fi
  )

  LIBS="-ltinfo" \
  SHLIB_LIBS="-ltinfo" \
  configure_make_install readline "${DEP_SOURCE_DIR}/readline" \
    bash_cv_termcap_lib=libtinfo \
    --with-curses \
    --enable-multibyte \
    --enable-shared=yes \
    --enable-static=no \
    --with-shared-termcap-library=-ltinfo \
    --disable-install-examples
else
  CFLAGS="${CFLAGS:-} -DNEED_EXTERN_PC=1 -D__USE_MINGW_ALARM -D_POSIX" \
  LIBS="-lncursesw" \
  SHLIB_LIBS="-lncursesw" \
  configure_make_install readline "${DEP_SOURCE_DIR}/readline" \
    bash_cv_termcap_lib=libncursesw \
    --without-curses \
    --enable-shared=yes \
    --enable-static=no \
    --with-shared-termcap-library=-lncursesw \
    --disable-install-examples
fi

configure_make_install libffi "${DEP_SOURCE_DIR}/libffi" \
  --enable-shared \
  --disable-static \
  --disable-symvers \
  --disable-docs

if [[ "$TARGET_KIND" == "mingw" ]]; then
  configure_make_install gettext "${DEP_SOURCE_DIR}/gettext/gettext-runtime" \
    lt_cv_deplibs_check_method=pass_all \
    --enable-shared \
    --disable-static \
    --enable-relocatable \
    --enable-threads=win32 \
    --disable-java \
    --disable-csharp \
    --disable-c++ \
    --disable-libasprintf
else
  configure_make_install gettext "${DEP_SOURCE_DIR}/gettext/gettext-runtime" \
    --enable-shared \
    --disable-static \
    --with-included-libintl \
    --disable-java \
    --disable-csharp \
    --disable-c++ \
    --disable-libasprintf
fi

copy_dependency_dlls_to_bin
remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_dynamic_libraries

render_template "${TEMPLATE_DIR}/README.llvmsdk-deps.in" "${SDK_PREFIX}/README.llvmsdk-deps" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "ZLIB_VERSION=${ZLIB_VERSION}" \
  "ZSTD_VERSION=${ZSTD_VERSION}" \
  "LZ4_VERSION=${LZ4_VERSION}" \
  "BZIP2_VERSION=${BZIP2_VERSION}" \
  "XZ_VERSION=${XZ_VERSION}" \
  "LIBICONV_VERSION=${LIBICONV_VERSION}" \
  "LIBXML2_VERSION=${LIBXML2_VERSION}" \
  "PCRE2_VERSION=${PCRE2_VERSION}" \
  "NCURSES_VERSION=${NCURSES_VERSION}" \
  "READLINE_VERSION=${READLINE_VERSION}" \
  "LIBFFI_VERSION=${LIBFFI_VERSION}" \
  "GETTEXT_VERSION=${GETTEXT_VERSION}" \
  "OPENSSL_VERSION=${OPENSSL_VERSION}"

log "LLVM SDK dependencies ready: ${SDK_PREFIX}"
