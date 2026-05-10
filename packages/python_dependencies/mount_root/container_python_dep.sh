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
  local archive_marker="${source_dir}/.python-dependencies-source-archive"

  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xf "${CACHE_DIR}/${archive_name}" -C "$source_dir" --strip-components=1
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

extract_zip_source() {
  local source_dir="$1"
  local archive_name="$2"
  local marker_path="$3"
  local tmp_dir="${source_dir}.extract"
  local extracted_dir=""
  local archive_marker="${source_dir}/.python-dependencies-source-archive"

  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir" "$tmp_dir"
    mkdir -p "$tmp_dir"
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "${CACHE_DIR}/${archive_name}" -d "$tmp_dir"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -m zipfile -e "${CACHE_DIR}/${archive_name}" "$tmp_dir"
    else
      die "unzip or python3 is required to extract ${archive_name}"
    fi
    while IFS= read -r marker_file; do
      extracted_dir="${marker_file%/${marker_path}}"
      break
    done < <(find "$tmp_dir" -path "*/${marker_path}" -type f -print | sort)
    [[ -n "$extracted_dir" && -e "${extracted_dir}/${marker_path}" ]] || die "invalid zip source archive: ${archive_name}"
    mkdir -p "$source_dir"
    cp -a "${extracted_dir}/." "$source_dir/"
    printf '%s\n' "$archive_name" >"$archive_marker"
    rm -rf "$tmp_dir"
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
      CC_FOR_BUILD="$BUILD_CC" \
      BUILD_CC="$BUILD_CC" \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBS="${LIBS:-}" \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
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
  local cmake_target_args=()
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cmake_target_args+=(-DCMAKE_DLL_NAME_WITH_SOVERSION=ON)
  fi

  log "Configuring dependency: ${package_name}"
  cmake -S "$source_dir" -B "$package_build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
    "${cmake_target_args[@]}" \
    "$@"

  log "Building dependency: ${package_name}"
  cmake --build "$package_build_dir" --parallel "$JOBS"
  cmake --install "$package_build_dir"
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man"
}

rewrite_dependency_prefixes() {
  local old_prefix="/opt/llvm_dependencies-${TARGET_TRIPLE}"
  local installed_file=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.py|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    if grep -IqF "$old_prefix" "$installed_file"; then
      sed -i "s#${old_prefix}#${SDK_PREFIX}#g" "$installed_file"
    fi
  done < <(
    find "$SDK_PREFIX" -type f -print0 2>/dev/null
  )
}

copy_dependency_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \;
}

build_curl() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cmake_install curl "${DEP_SOURCE_DIR}/curl" \
      "-DOPENSSL_ROOT_DIR=${SDK_PREFIX}" \
      "-DZLIB_ROOT=${SDK_PREFIX}" \
      -DCMAKE_UNITY_BUILD=ON \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_STATIC_LIBS=OFF \
      -DBUILD_CURL_EXE=ON \
      -DPICKY_COMPILER=OFF \
      -DBUILD_EXAMPLES=OFF \
      -DBUILD_LIBCURL_DOCS=OFF \
      -DBUILD_MISC_DOCS=OFF \
      -DBUILD_TESTING=OFF \
      -DCURL_DISABLE_INSTALL_DOCS=ON \
      -DCURL_DEFAULT_SSL_BACKEND=openssl \
      -DCURL_ENABLE_SSL=ON \
      -DCURL_USE_OPENSSL=ON \
      -DCURL_USE_LIBSSH2=OFF \
      -DCURL_USE_LIBPSL=OFF \
      -DCURL_BROTLI=OFF \
      -DCURL_ZSTD=OFF \
      -DUSE_LIBIDN2=OFF \
      -DUSE_NGHTTP2=OFF \
      -DUSE_NGHTTP3=OFF \
      -DUSE_NGTCP2=OFF \
      -DENABLE_CURL_MANUAL=OFF \
      -DENABLE_UNICODE=OFF \
      -DCURL_USE_SCHANNEL=OFF \
      -DCURL_WINDOWS_SSPI=ON
  else
    configure_make_install curl "${DEP_SOURCE_DIR}/curl" \
      --enable-shared \
      --disable-static \
      --disable-dependency-tracking \
      "--with-openssl=${SDK_PREFIX}" \
      "--with-zlib=${SDK_PREFIX}" \
      --disable-ldap \
      --disable-ldaps \
      --disable-docs \
      --disable-manual \
      --without-brotli \
      --without-libidn2 \
      --without-libpsl \
      --without-libssh2 \
      --without-nghttp2 \
      --without-nghttp3 \
      --without-ngtcp2 \
      --without-zstd
  fi
}

build_libxslt() {
  local libxslt_args=()

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    # libxslt's CMake probe can mistake MinGW's _strxfrm_l for POSIX strxfrm_l.
    libxslt_args+=(-DHAVE_STRXFRM_L=OFF)
  fi

  cmake_install libxslt "${DEP_SOURCE_DIR}/libxslt" \
    "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
    "-DCMAKE_SHARED_LINKER_FLAGS=${LIBXSLT_SHARED_LINKER_FLAGS}" \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBXSLT_WITH_CRYPTO=OFF \
    -DLIBXSLT_WITH_DEBUGGER=OFF \
    -DLIBXSLT_WITH_PROGRAMS=OFF \
    -DLIBXSLT_WITH_PYTHON=OFF \
    -DLIBXSLT_WITH_TESTS=OFF \
    "-DLibXml2_DIR=${SDK_PREFIX}/lib/cmake/libxml2" \
    "${libxslt_args[@]}"
}

build_sqlite() {
  local sqlite_args=(
    --enable-shared
    --disable-static
    --disable-rpath
    --all
    --session
    --disable-readline
  )

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    sqlite_args+=(--out-implib)
  fi

  configure_make_install sqlite "${DEP_SOURCE_DIR}/sqlite" "${sqlite_args[@]}"
}

require_path() {
  local path="$1"
  [[ -e "$path" ]] || die "missing required dependency artifact: $path"
}

require_glob() {
  local pattern="$1"
  compgen -G "$pattern" >/dev/null || die "missing required dependency artifact: $pattern"
}

build_icu() {
  local source_dir="$1"
  local host_build_dir="${DEP_BUILD_DIR}/icu-host"
  local target_build_dir="${DEP_BUILD_DIR}/icu-target"
  local host_prefix="${BUILD_TOOLS}/host-icu"
  local target_configure_args=()

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    target_configure_args+=(--with-data-packaging=dll)
  fi

  rm -rf "$host_build_dir" "$target_build_dir" "$host_prefix"
  mkdir -p "$host_build_dir" "$target_build_dir" "$host_prefix"

  log "Building host ICU tools"
  (
    cd "$host_build_dir"
    env \
      CC="${BUILD_CC}" \
      CXX="${BUILD_CXX}" \
      AR="${LLVM_ROOT}/bin/llvm-ar" \
      RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
      STRIP="${LLVM_ROOT}/bin/llvm-strip" \
      CPPFLAGS= \
      CFLAGS= \
      CXXFLAGS= \
      LDFLAGS= \
      /bin/sh "${source_dir}/source/configure" \
        --prefix="$host_prefix" \
        --disable-rpath \
        --enable-shared \
        --disable-static \
        --disable-samples \
        --disable-tests
    make -j "$JOBS"
  )

  log "Configuring dependency: icu4c"
  (
    cd "$target_build_dir"
    export PATH="${BUILD_TOOLS}:${PATH}"
    env \
      CC="$CC" \
      CXX="$CXX" \
      LD="$LD" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      /bin/sh "${source_dir}/source/configure" \
        --build="$BUILD_TRIPLE" \
        --host="$CONFIGURE_HOST_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        --with-cross-build="$host_build_dir" \
        --disable-rpath \
        --enable-shared \
        --disable-static \
        --disable-samples \
        --disable-tests \
        "${target_configure_args[@]}"
    make -j "$JOBS"
    make install
  )
}

validate_dynamic_libraries() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    require_glob "${SDK_PREFIX}/bin/libcurl*.dll"
    require_glob "${SDK_PREFIX}/bin/libexpat*.dll"
    require_glob "${SDK_PREFIX}/bin/libsqlite3*.dll"
    require_glob "${SDK_PREFIX}/bin/libxslt*.dll"
    require_glob "${SDK_PREFIX}/bin/libexslt*.dll"
    require_glob "${SDK_PREFIX}/bin/icudt*.dll"
    require_glob "${SDK_PREFIX}/bin/icuin*.dll"
    require_glob "${SDK_PREFIX}/bin/icuuc*.dll"

    require_glob "${SDK_PREFIX}/lib/libcurl*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libexpat*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libsqlite3*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libxslt*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libexslt*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libicudt*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libicuin*.dll.a"
    require_glob "${SDK_PREFIX}/lib/libicuuc*.dll.a"
  else
    require_path "${SDK_PREFIX}/lib/libcurl.so"
    require_path "${SDK_PREFIX}/lib/libuuid.so"
    require_path "${SDK_PREFIX}/lib/libexpat.so"
    require_path "${SDK_PREFIX}/lib/libsqlite3.so"
    require_path "${SDK_PREFIX}/lib/libgdbm.so"
    require_path "${SDK_PREFIX}/lib/libgdbm_compat.so"
    require_path "${SDK_PREFIX}/lib/libxslt.so"
    require_path "${SDK_PREFIX}/lib/libexslt.so"
    require_path "${SDK_PREFIX}/lib/libicudata.so"
    require_path "${SDK_PREFIX}/lib/libicui18n.so"
    require_path "${SDK_PREFIX}/lib/libicuuc.so"
  fi
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/python_dependencies-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

CURL_VERSION="${CURL_VERSION:-8.20.0}"
UTIL_LINUX_VERSION="${UTIL_LINUX_VERSION:-2.42}"
EXPAT_VERSION="${EXPAT_VERSION:-2.8.0}"
SQLITE_VERSION="${SQLITE_VERSION:-3530000}"
GDBM_VERSION="${GDBM_VERSION:-1.26}"
LIBXSLT_VERSION="${LIBXSLT_VERSION:-1.1.45}"
ICU_VERSION="${ICU_VERSION:-78.3}"

CURL_ARCHIVE_NAME="curl-${CURL_VERSION}.tar.gz"
UTIL_LINUX_ARCHIVE_NAME="util-linux-${UTIL_LINUX_VERSION}.tar.xz"
EXPAT_ARCHIVE_NAME="expat-${EXPAT_VERSION}.tar.xz"
SQLITE_ARCHIVE_NAME="sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
GDBM_ARCHIVE_NAME="gdbm-${GDBM_VERSION}.tar.gz"
LIBXSLT_ARCHIVE_NAME="libxslt-v${LIBXSLT_VERSION}.tar.bz2"
ICU_ARCHIVE_NAME="icu4c-${ICU_VERSION}-sources.tgz"

CURL_ARCHIVE_URL="${CURL_ARCHIVE_URL:-https://curl.se/download/${CURL_ARCHIVE_NAME}}"
UTIL_LINUX_ARCHIVE_URL="${UTIL_LINUX_ARCHIVE_URL:-https://www.kernel.org/pub/linux/utils/util-linux/v${UTIL_LINUX_VERSION}/${UTIL_LINUX_ARCHIVE_NAME}}"
EXPAT_ARCHIVE_URL="${EXPAT_ARCHIVE_URL:-https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/${EXPAT_ARCHIVE_NAME}}"
SQLITE_ARCHIVE_URL="${SQLITE_ARCHIVE_URL:-https://sqlite.org/2026/${SQLITE_ARCHIVE_NAME}}"
GDBM_ARCHIVE_URL="${GDBM_ARCHIVE_URL:-https://ftp.gnu.org/gnu/gdbm/${GDBM_ARCHIVE_NAME}}"
LIBXSLT_ARCHIVE_URL="${LIBXSLT_ARCHIVE_URL:-https://gitlab.gnome.org/GNOME/libxslt/-/archive/v${LIBXSLT_VERSION}/${LIBXSLT_ARCHIVE_NAME}}"
ICU_ARCHIVE_URL="${ICU_ARCHIVE_URL:-https://github.com/unicode-org/icu/releases/download/release-${ICU_VERSION}/${ICU_ARCHIVE_NAME}}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing base dependency prefix: ${SDK_PREFIX}"

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
  CONFIGURE_BUILD_TRIPLE="${ARCH}-pythondepsbuild-linux-gnu"
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
TOOLCHAIN_FILE="${BUILD_DIR}/python-deps-toolchain.cmake"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"

mkdir -p "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS"

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
fi

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/ncursesw"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi
LIBXSLT_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS"
if [[ "$TARGET_KIND" == "linux" ]]; then
  LIBXSLT_SHARED_LINKER_FLAGS="${LIBXSLT_SHARED_LINKER_FLAGS} -Wl,--undefined-version"
fi
RC_FLAGS="${RC_FLAGS:-}"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  RC_FLAGS="-I${SYSROOT}/usr/${TARGET_TRIPLE}/include -I${TARGET_ROOT}/include ${RC_FLAGS}"
fi

write_toolchain_file
rewrite_dependency_prefixes

download_archive "$CURL_ARCHIVE_URL" "$CURL_ARCHIVE_NAME"
download_archive "$EXPAT_ARCHIVE_URL" "$EXPAT_ARCHIVE_NAME"
download_archive "$SQLITE_ARCHIVE_URL" "$SQLITE_ARCHIVE_NAME"
download_archive "$LIBXSLT_ARCHIVE_URL" "$LIBXSLT_ARCHIVE_NAME"
download_archive "$ICU_ARCHIVE_URL" "$ICU_ARCHIVE_NAME"
if [[ "$TARGET_KIND" == "linux" ]]; then
  download_archive "$UTIL_LINUX_ARCHIVE_URL" "$UTIL_LINUX_ARCHIVE_NAME"
  download_archive "$GDBM_ARCHIVE_URL" "$GDBM_ARCHIVE_NAME"
fi

extract_archive_source "${DEP_SOURCE_DIR}/curl" "$CURL_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/expat" "$EXPAT_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/sqlite" "$SQLITE_ARCHIVE_NAME" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libxslt" "$LIBXSLT_ARCHIVE_NAME" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/icu" "$ICU_ARCHIVE_NAME" "source/configure"
if [[ "$TARGET_KIND" == "linux" ]]; then
  extract_archive_source "${DEP_SOURCE_DIR}/util-linux" "$UTIL_LINUX_ARCHIVE_NAME" "configure"
  extract_archive_source "${DEP_SOURCE_DIR}/gdbm" "$GDBM_ARCHIVE_NAME" "configure"
fi

log "Installing Python dependencies into ${SDK_PREFIX}"

build_curl

if [[ "$TARGET_KIND" == "linux" ]]; then
  configure_make_install libuuid "${DEP_SOURCE_DIR}/util-linux" \
    --disable-all-programs \
    --enable-libuuid \
    --disable-libblkid \
    --disable-libmount \
    --disable-libsmartcols \
    --disable-nls \
    --without-python \
    --without-systemd
fi

cmake_install expat "${DEP_SOURCE_DIR}/expat" \
  -DEXPAT_SHARED_LIBS=ON \
  -DEXPAT_BUILD_TOOLS=OFF \
  -DEXPAT_BUILD_EXAMPLES=OFF \
  -DEXPAT_BUILD_TESTS=OFF \
  -DEXPAT_BUILD_DOCS=OFF

build_sqlite

if [[ "$TARGET_KIND" == "linux" ]]; then
  configure_make_install gdbm "${DEP_SOURCE_DIR}/gdbm" \
    --enable-libgdbm-compat \
    --enable-shared \
    --disable-static \
    --disable-nls \
    --disable-dependency-tracking
fi

build_libxslt

build_icu "${DEP_SOURCE_DIR}/icu"

rewrite_dependency_prefixes
copy_dependency_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_dynamic_libraries

render_template "${TEMPLATE_DIR}/README.python-dependencies.in" "${SDK_PREFIX}/README.python-dependencies" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "CURL_VERSION=${CURL_VERSION}" \
  "UTIL_LINUX_VERSION=${UTIL_LINUX_VERSION}" \
  "EXPAT_VERSION=${EXPAT_VERSION}" \
  "SQLITE_VERSION=${SQLITE_VERSION}" \
  "GDBM_VERSION=${GDBM_VERSION}" \
  "LIBXSLT_VERSION=${LIBXSLT_VERSION}" \
  "ICU_VERSION=${ICU_VERSION}"

log "Python dependencies ready: ${SDK_PREFIX}"
