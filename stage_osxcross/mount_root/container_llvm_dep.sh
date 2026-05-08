#!/usr/bin/env bash

set -euo pipefail

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

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env sh
exec "${real_compiler}" --target="${TARGET_TRIPLE}" --sysroot="${SYSROOT}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_windres_wrapper() {
  local wrapper_path="$1"
  local real_windres="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env sh
exec "${real_windres}" -I"${SYSROOT}/usr/${TARGET_TRIPLE}/include" -I"${TARGET_ROOT}/include" "\$@"
EOF
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
  cat >"$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME ${CMAKE_SYSTEM_NAME})
set(CMAKE_SYSTEM_PROCESSOR ${CMAKE_SYSTEM_PROCESSOR})
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_C_COMPILER "${CC}")
set(CMAKE_CXX_COMPILER "${CXX}")
set(CMAKE_AR "${AR}")
set(CMAKE_LINKER "${LD}")
set(CMAKE_NM "${NM}")
set(CMAKE_OBJCOPY "${OBJCOPY}")
set(CMAKE_RANLIB "${RANLIB}")
set(CMAKE_STRIP "${STRIP}")
set(CMAKE_RC_COMPILER "${RC}")
set(CMAKE_RC_FLAGS "${RC_FLAGS}")
set(CMAKE_SYSROOT "${SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${SDK_PREFIX};${SYSROOT};${TARGET_ROOT};${LLVM_ROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_PREFIX_PATH "${SDK_PREFIX}")
EOF
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
LIBICONV_VERSION="${LIBICONV_VERSION:-1.19}"
LIBXML2_VERSION="${LIBXML2_VERSION:-2.15.3}"
PCRE2_VERSION="${PCRE2_VERSION:-10.47}"
NCURSES_VERSION="${NCURSES_VERSION:-6.6}"
READLINE_VERSION="${READLINE_VERSION:-8.3}"
LIBFFI_VERSION="${LIBFFI_VERSION:-3.5.2}"
GETTEXT_VERSION="${GETTEXT_VERSION:-1.0}"

ZLIB_ARCHIVE_NAME="zlib-${ZLIB_VERSION}.tar.gz"
ZSTD_ARCHIVE_NAME="zstd-${ZSTD_VERSION}.tar.gz"
LIBICONV_ARCHIVE_NAME="libiconv-${LIBICONV_VERSION}.tar.gz"
LIBXML2_ARCHIVE_NAME="libxml2-v${LIBXML2_VERSION}.tar.bz2"
PCRE2_ARCHIVE_NAME="pcre2-${PCRE2_VERSION}.tar.gz"
NCURSES_ARCHIVE_NAME="ncurses-${NCURSES_VERSION}.tar.gz"
READLINE_ARCHIVE_NAME="readline-${READLINE_VERSION}.tar.gz"
LIBFFI_ARCHIVE_NAME="libffi-${LIBFFI_VERSION}.tar.gz"
GETTEXT_ARCHIVE_NAME="gettext-${GETTEXT_VERSION}.tar.gz"

ZLIB_ARCHIVE_URL="${ZLIB_ARCHIVE_URL:-https://zlib.net/${ZLIB_ARCHIVE_NAME}}"
ZSTD_ARCHIVE_URL="${ZSTD_ARCHIVE_URL:-https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/${ZSTD_ARCHIVE_NAME}}"
LIBICONV_ARCHIVE_URL="${LIBICONV_ARCHIVE_URL:-https://ftp.gnu.org/pub/gnu/libiconv/${LIBICONV_ARCHIVE_NAME}}"
LIBXML2_ARCHIVE_URL="${LIBXML2_ARCHIVE_URL:-https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML2_VERSION}/${LIBXML2_ARCHIVE_NAME}}"
PCRE2_ARCHIVE_URL="${PCRE2_ARCHIVE_URL:-https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/${PCRE2_ARCHIVE_NAME}}"
NCURSES_ARCHIVE_URL="${NCURSES_ARCHIVE_URL:-https://ftp.gnu.org/gnu/ncurses/${NCURSES_ARCHIVE_NAME}}"
READLINE_ARCHIVE_URL="${READLINE_ARCHIVE_URL:-https://ftp.gnu.org/gnu/readline/${READLINE_ARCHIVE_NAME}}"
LIBFFI_ARCHIVE_URL="${LIBFFI_ARCHIVE_URL:-https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/${LIBFFI_ARCHIVE_NAME}}"
GETTEXT_ARCHIVE_URL="${GETTEXT_ARCHIVE_URL:-https://ftp.gnu.org/pub/gnu/gettext/${GETTEXT_ARCHIVE_NAME}}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"

require_command curl
require_command tar
require_command make
require_command cmake
require_command ninja

case "$TARGET_KIND" in
  linux)
    CMAKE_SYSTEM_NAME="Linux"
    CMAKE_SYSTEM_PROCESSOR="$ARCH"
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    ;;
  mingw)
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-x86_64-w64-mingw32}"
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
  cat >"${BUILD_TOOLS}/strip" <<EOF
#!/usr/bin/env bash
set -euo pipefail

filtered_args=()
for arg in "\$@"; do
  case "\$arg" in
    -p|--preserve-dates)
      ;;
    *)
      filtered_args+=("\$arg")
      ;;
  esac
done

exec "${STRIP}" "\${filtered_args[@]}"
EOF
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
download_archive "$LIBICONV_ARCHIVE_URL" "$LIBICONV_ARCHIVE_NAME"
download_archive "$LIBXML2_ARCHIVE_URL" "$LIBXML2_ARCHIVE_NAME"
download_archive "$PCRE2_ARCHIVE_URL" "$PCRE2_ARCHIVE_NAME"
download_archive "$NCURSES_ARCHIVE_URL" "$NCURSES_ARCHIVE_NAME"
download_archive "$READLINE_ARCHIVE_URL" "$READLINE_ARCHIVE_NAME"
download_archive "$LIBFFI_ARCHIVE_URL" "$LIBFFI_ARCHIVE_NAME"
download_archive "$GETTEXT_ARCHIVE_URL" "$GETTEXT_ARCHIVE_NAME"

extract_archive_source "${DEP_SOURCE_DIR}/zlib" "$ZLIB_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/zstd" "$ZSTD_ARCHIVE_NAME" "build/cmake/CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/libiconv" "$LIBICONV_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libxml2" "$LIBXML2_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/pcre2" "$PCRE2_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/ncurses" "$NCURSES_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/readline" "$READLINE_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libffi" "$LIBFFI_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/gettext" "$GETTEXT_ARCHIVE_NAME" "configure"

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

log "Installing LLVM SDK dependencies into ${SDK_PREFIX}"

cmake_install zlib "${DEP_SOURCE_DIR}/zlib" \
  -DBUILD_SHARED_LIBS=ON \
  -DZLIB_BUILD_TESTING=OFF \
  -DZLIB_BUILD_MINIZIP=OFF \
  -DZLIB_INSTALL=ON

cmake_install zstd "${DEP_SOURCE_DIR}/zstd/build/cmake" \
  -DZSTD_BUILD_SHARED=ON \
  -DZSTD_BUILD_STATIC=ON \
  -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_BUILD_TESTS=OFF \
  -DZSTD_BUILD_CONTRIB=OFF \
  -DZSTD_MULTITHREAD_SUPPORT=ON \
  -DZSTD_LEGACY_SUPPORT=OFF

configure_make_install libiconv "${DEP_SOURCE_DIR}/libiconv" \
  --enable-shared \
  --enable-static

cmake_install libxml2 "${DEP_SOURCE_DIR}/libxml2" \
  "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
  -DBUILD_SHARED_LIBS=ON \
  -DLIBXML2_WITH_ICONV=ON \
  -DLIBXML2_WITH_ICU=OFF \
  -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_MODULES=OFF \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_ZLIB=ON \
  "-DIconv_INCLUDE_DIR=${SDK_PREFIX}/include" \
  "-DIconv_LIBRARY=${SDK_PREFIX}/lib/libiconv.a"

cmake_install pcre2 "${DEP_SOURCE_DIR}/pcre2" \
  -DBUILD_SHARED_LIBS=ON \
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

  tic_path="${BUILD_TOOLS}/host-ncurses/bin/tic" \
  configure_make_install ncurses "${DEP_SOURCE_DIR}/ncurses" \
    --with-shared \
    --with-normal \
    --without-profile \
    --without-debug \
    --without-cxx \
    --without-cxx-binding \
    --without-ada \
    --without-manpages \
    --without-tests \
    --without-progs \
    --enable-echo \
    --enable-const \
    --enable-widec \
    --with-termlib \
    --disable-term-driver \
    --disable-termcap \
    --enable-pc-files \
    "--with-tic-path=${BUILD_TOOLS}/host-ncurses/bin/tic" \
    "--with-pkg-config-libdir=${SDK_PREFIX}/lib/pkgconfig"
fi

LIBS="-lncursesw" \
SHLIB_LIBS="-lncursesw" \
configure_make_install readline "${DEP_SOURCE_DIR}/readline" \
  bash_cv_termcap_lib=libncursesw \
  --enable-shared=yes \
  --enable-static=yes \
  --with-shared-termcap-library=-lncursesw \
  --disable-install-examples

configure_make_install libffi "${DEP_SOURCE_DIR}/libffi" \
  --enable-shared \
  --enable-static \
  --disable-symvers \
  --disable-docs

configure_make_install gettext "${DEP_SOURCE_DIR}/gettext/gettext-runtime" \
  --enable-shared \
  --enable-static \
  --disable-java \
  --disable-csharp \
  --disable-c++ \
  --disable-libasprintf

copy_dependency_dlls_to_bin

cat >"${SDK_PREFIX}/README.llvmsdk-deps" <<EOF
LLVM SDK dependency prefix.

Target triple: ${TARGET_TRIPLE}
Target kind: ${TARGET_KIND}

Included dependency sources:
  zlib ${ZLIB_VERSION}
  zstd ${ZSTD_VERSION}
libiconv ${LIBICONV_VERSION}
libxml2 ${LIBXML2_VERSION}
pcre2 ${PCRE2_VERSION}
ncurses ${NCURSES_VERSION}
readline ${READLINE_VERSION}
libffi ${LIBFFI_VERSION}
  gettext ${GETTEXT_VERSION}
EOF

log "LLVM SDK dependencies ready: ${SDK_PREFIX}"
