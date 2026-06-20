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
  local archive_name="$2"
  local marker_path="$3"
  local archive_marker="${source_dir}/.source-archive"

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

apply_source_patch() {
  local source_dir="$1"
  local patch_path="$2"
  local marker_path="${source_dir}/.applied-$(basename "$patch_path")"

  [[ -f "$patch_path" ]] || die "missing patch: ${patch_path}"
  (
    cd "$source_dir"
    if patch -N -p1 --dry-run -i "$patch_path" >/dev/null; then
      patch -N -p1 -i "$patch_path"
      touch "$marker_path"
    elif patch -R -p1 --dry-run -i "$patch_path" >/dev/null; then
      touch "$marker_path"
    else
      die "patch cannot be applied cleanly: ${patch_path}"
    fi
  )
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
    "WINDRES_TARGET=${WINDRES_TARGET}" \
    "MINGW_INCLUDE_DIR=${MINGW_INCLUDE_DIR}"
  chmod +x "$wrapper_path"
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
  local configure_ld="$LD"
  local libtool_cache_env=()
  local configure_ldflags="$COMMON_LDFLAGS ${LDFLAGS:-}"
  local make_ldflags="$configure_ldflags"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    configure_ld="$CC"
    make_ldflags="${make_ldflags} -no-undefined"
    libtool_cache_env+=(lt_cv_prog_gnu_ld=yes lt_cv_prog_gnu_ldcxx=yes lt_cv_deplibs_check_method=pass_all)
  fi

  log "Configuring dependency: ${package_name}"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    env \
      "${libtool_cache_env[@]}" \
      CC="$CC" \
      CXX="$CXX" \
      LD="$configure_ld" \
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
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR= \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$configure_ldflags" \
      LIBS="${LIBS:-}" \
      "${source_dir}/configure" \
        --build="$CONFIGURE_BUILD_TRIPLE" \
        --host="$CONFIGURE_HOST_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        "$@"
    make -j "$JOBS" LDFLAGS="$make_ldflags"
    make install LDFLAGS="$make_ldflags"
  )
}

cmake_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  local cmake_target_args=()
  local cmake_rpath_args=()
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cmake_target_args+=(-DCMAKE_DLL_NAME_WITH_SOVERSION=ON)
  else
    cmake_rpath_args+=(
      "-DCMAKE_INSTALL_RPATH=${SDK_PREFIX}/lib"
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF
      -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF
    )
  fi

  log "Configuring dependency: ${package_name}"
  env \
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
    PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR= \
    cmake -S "$source_dir" -B "$package_build_dir" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
      -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="$COMMON_CFLAGS -Qunused-arguments" \
      -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS -Qunused-arguments" \
      -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
      -DCMAKE_MODULE_LINKER_FLAGS="$COMMON_LDFLAGS" \
      "${cmake_target_args[@]}" \
      "${cmake_rpath_args[@]}" \
      "$@"

  log "Building dependency: ${package_name}"
  LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    cmake --build "$package_build_dir" --parallel "$JOBS"
  LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    cmake --install "$package_build_dir"
}

rewrite_linux_absolute_needed() {
  local file_path=""
  local needed_entry=""
  local needed_name=""

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  require_command patchelf

  while IFS= read -r -d '' file_path; do
    while IFS= read -r needed_entry; do
      case "$needed_entry" in
        "${SDK_PREFIX}/lib/"*.so*)
          needed_name="$(basename "$needed_entry")"
          patchelf --replace-needed "$needed_entry" "$needed_name" "$file_path"
          ;;
      esac
    done < <(patchelf --print-needed "$file_path" 2>/dev/null || true)
  done < <(
    find "${SDK_PREFIX}/bin" "${SDK_PREFIX}/lib" \
      -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) \
      -print0 2>/dev/null
  )
}

copy_mingw_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name '*.la' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name '*.a' ! -name '*.dll.a' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib/pkgconfig" -type f -name '*static*.pc' -delete 2>/dev/null || true
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man" "${SDK_PREFIX}/share/info"
}

build_unixodbc() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  configure_make_install unixodbc "${DEP_SOURCE_DIR}/unixodbc" \
    --enable-shared \
    --disable-static \
    --disable-gui \
    --disable-drivers \
    --disable-driver-conf \
    --disable-iconv
}

build_freetds() {
  local odbc_args=(--disable-odbc)
  local odbc_config_path="${SDK_PREFIX}/bin/odbc_config"
  local hidden_odbc_config_path="${SDK_PREFIX}/bin/odbc_config.target"

  if [[ "$TARGET_KIND" == "linux" ]]; then
    odbc_args=(--with-unixodbc="$SDK_PREFIX")
    if [[ -f "$odbc_config_path" ]]; then
      mv "$odbc_config_path" "$hidden_odbc_config_path"
    fi
  fi

  configure_make_install freetds "${DEP_SOURCE_DIR}/freetds" \
    --enable-shared \
    --disable-static \
    --disable-server \
    --disable-apps \
    --with-tdsver=7.4 \
    --disable-libiconv \
    "${odbc_args[@]}"

  if [[ -f "$hidden_odbc_config_path" ]]; then
    mv "$hidden_odbc_config_path" "$odbc_config_path"
  fi
}

build_mariadb_connector_c() {
  local ssl_arg="-DWITH_SSL=OPENSSL"
  local platform_args=()

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    ssl_arg="-DWITH_SSL=SCHANNEL"
    platform_args+=(-DHAVE_NL_LANGINFO:INTERNAL=)
  fi

  cmake_install mariadb-connector-c "${DEP_SOURCE_DIR}/mariadb-connector-c" \
    "$ssl_arg" \
    "${platform_args[@]}" \
    -DWITH_UNIT_TESTS=OFF \
    -DWITH_EXTERNAL_ZLIB=OFF \
    -DWITH_CURL=OFF \
    -DWITH_MYSQLCOMPAT=ON \
    -DWITH_STATIC=OFF
}

build_hiredis() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch "${DEP_SOURCE_DIR}/hiredis" "${PATCH_DIR}/hiredis-1.4.0-mingw-clock.patch"
  fi

  cmake_install hiredis "${DEP_SOURCE_DIR}/hiredis" \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_SSL=OFF \
    -DDISABLE_TESTS=ON
}

build_mongo_c_driver() {
  local ssl_arg="-DENABLE_SSL=OPENSSL"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    ssl_arg="-DENABLE_SSL=WINDOWS"
    case "$MONGO_C_DRIVER_VERSION" in
      1.30.8)
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-1.30.8-mingw-windns.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-1.30.8-mingw-mstcpip.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-1.30.8-mingw-dnsapi-lib.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-1.30.8-mingw-bcrypt.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-1.30.8-mingw-libbson-clock-gettime.patch"
        ;;
      2.3.1)
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-2.3.1-mingw-windns.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-2.3.1-mingw-mstcpip.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-2.3.1-mingw-dnsapi-lib.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-2.3.1-mingw-bcrypt.patch"
        apply_source_patch "${DEP_SOURCE_DIR}/mongo-c-driver" "${PATCH_DIR}/mongo-c-driver-2.3.1-mingw-libbson-clock-gettime.patch"
        ;;
      *)
        die "unsupported mongo-c-driver MinGW patch version: ${MONGO_C_DRIVER_VERSION}"
        ;;
    esac
    ! grep -Rqs '#include <WinDNS.h>\|#include <Windows.h>' "${DEP_SOURCE_DIR}/mongo-c-driver/src/libmongoc/src/mongoc/mongoc-client.c" \
      || die "mongo-c-driver MinGW header patch did not take effect"
    ! grep -Rqs '#include <Mstcpip.h>' "${DEP_SOURCE_DIR}/mongo-c-driver/src/libmongoc/src/mongoc/mongoc-socket.c" \
      || die "mongo-c-driver MinGW socket header patch did not take effect"
    ! grep -Rqs 'Bcrypt\.lib' "${DEP_SOURCE_DIR}/mongo-c-driver/src/libmongoc/CMakeLists.txt" \
      || die "mongo-c-driver MinGW bcrypt library patch did not take effect"
  fi

  cmake_install mongo-c-driver "${DEP_SOURCE_DIR}/mongo-c-driver" \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_MAN_PAGES=OFF \
    -DENABLE_HTML_DOCS=OFF \
    "$ssl_arg" \
    -DENABLE_SASL=OFF \
    -DENABLE_SNAPPY=OFF \
    -DENABLE_ZLIB=BUNDLED \
    -DENABLE_ZSTD=OFF \
    -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF
}

validate_fdw_dependencies() {
  if [[ "$TARGET_KIND" == "linux" ]]; then
    [[ -f "${SDK_PREFIX}/include/sql.h" ]] || die "missing unixODBC headers"
    find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libodbc.so*' | grep -q . || die "missing unixODBC shared library"
  fi

  [[ -f "${SDK_PREFIX}/include/sybfront.h" || -f "${SDK_PREFIX}/include/freetds/sybfront.h" ]] || die "missing FreeTDS headers"
  [[ -f "${SDK_PREFIX}/include/mysql/mysql.h" || -f "${SDK_PREFIX}/include/mariadb/mysql.h" ]] || die "missing MariaDB/MySQL headers"
  [[ -f "${SDK_PREFIX}/include/hiredis/hiredis.h" ]] || die "missing hiredis headers"
  [[ -f "${SDK_PREFIX}/include/libmongoc-1.0/mongoc/mongoc.h" || -f "${SDK_PREFIX}/include/mongoc-${MONGO_C_DRIVER_VERSION}/mongoc/mongoc.h" ]] || die "missing mongo-c-driver headers"
  [[ -f "${SDK_PREFIX}/include/libbson-1.0/bson/bson.h" || -f "${SDK_PREFIX}/include/bson-${MONGO_C_DRIVER_VERSION}/bson/bson.h" ]] || die "missing libbson headers"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "$SDK_PREFIX" \( -type f -o -type l \) \( -name '*sybdb*.dll' -o -name '*sybdb*.dll.a' \) | grep -q . || die "missing FreeTDS DLL/import library"
    find "$SDK_PREFIX" \( -type f -o -type l \) \( -name '*mariadb*.dll' -o -name '*mariadb*.dll.a' \) | grep -q . || die "missing MariaDB DLL/import library"
    find "$SDK_PREFIX" \( -type f -o -type l \) \( -name '*hiredis*.dll' -o -name '*hiredis*.dll.a' \) | grep -q . || die "missing hiredis DLL/import library"
    find "$SDK_PREFIX" \( -type f -o -type l \) \( -name '*mongoc*.dll' -o -name '*mongoc*.dll.a' \) | grep -q . || die "missing mongo-c-driver DLL/import library"
    return 0
  fi

  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libsybdb.so*' | grep -q . || die "missing FreeTDS shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libmariadb.so*' | grep -q . || die "missing MariaDB shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libhiredis.so*' | grep -q . || die "missing hiredis shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) \( -name 'libmongoc-*.so*' -o -name 'libmongoc2.so*' \) | grep -q . || die "missing mongo-c-driver shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) \( -name 'libbson-*.so*' -o -name 'libbson2.so*' \) | grep -q . || die "missing libbson shared library"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/fdw_dependencies-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

UNIXODBC_VERSION="${UNIXODBC_VERSION:-2.3.14}"
FREETDS_VERSION="${FREETDS_VERSION:-1.5.16}"
MARIADB_VERSION="${MARIADB_VERSION:-3.4.9}"
HIREDIS_VERSION="${HIREDIS_VERSION:-1.4.0}"
MONGO_C_DRIVER_VERSION="${MONGO_C_DRIVER_VERSION:-1.30.8}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing FDW dependency prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make
require_command cmake
require_command ninja
require_command patch
require_command pkg-config

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CMAKE_SYSTEM_NAME="Linux"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    RC_FLAGS="${RC_FLAGS:-}"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CMAKE_SYSTEM_NAME="Windows"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-x86_64-w64-mingw32}"
    WINDRES_TARGET="${WINDRES_TARGET:-pe-x86-64}"
    MINGW_INCLUDE_DIR="${MINGW_INCLUDE_DIR:-${SYSROOT}/usr/${TARGET_TRIPLE}/include}"
    [[ -d "$MINGW_INCLUDE_DIR" ]] || die "missing MinGW include directory: ${MINGW_INCLUDE_DIR}"
    RC_FLAGS="-I${MINGW_INCLUDE_DIR} ${RC_FLAGS:-}"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

case "$ARCH" in
  x86_64) CMAKE_SYSTEM_PROCESSOR="x86_64" ;;
  aarch64) CMAKE_SYSTEM_PROCESSOR="aarch64" ;;
  riscv64) CMAKE_SYSTEM_PROCESSOR="riscv64" ;;
  loongarch64) CMAKE_SYSTEM_PROCESSOR="loongarch64" ;;
  *) die "unsupported ARCH: ${ARCH}" ;;
esac

BUILD_TRIPLE="$("${LLVM_ROOT}/bin/clang" -dumpmachine 2>/dev/null || echo x86_64-unknown-linux-gnu)"
CONFIGURE_BUILD_TRIPLE="${CONFIGURE_BUILD_TRIPLE:-$BUILD_TRIPLE}"
if [[ "$CONFIGURE_BUILD_TRIPLE" == "$CONFIGURE_HOST_TRIPLE" ]]; then
  CONFIGURE_BUILD_TRIPLE="${ARCH}-fdwdepsbuild-linux-gnu"
fi

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
BUILD_CXX="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"

if [[ "$TARGET_KIND" == "mingw" ]]; then
  CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
  CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
else
  CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang}"
  CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang++}"
fi
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
LD="${LD:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ld}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy}"
OBJDUMP="${OBJDUMP:-${LLVM_ROOT}/bin/llvm-objdump}"
DLLTOOL="${DLLTOOL:-${LLVM_ROOT}/bin/llvm-dlltool}"
RC="${RC:-${LLVM_ROOT}/bin/llvm-windres}"

[[ -x "$BUILD_CC" ]] || die "missing build compiler: ${BUILD_CC}"
[[ -x "$BUILD_CXX" ]] || die "missing build C++ compiler: ${BUILD_CXX}"
[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$LD" ]] || LD="${LLVM_ROOT}/bin/ld.lld"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$OBJCOPY" ]] || OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy"
[[ -x "$OBJDUMP" ]] || OBJDUMP="${LLVM_ROOT}/bin/llvm-objdump"
[[ -x "$DLLTOOL" ]] || DLLTOOL="${LLVM_ROOT}/bin/llvm-dlltool"
[[ -x "$RC" ]] || RC="${LLVM_ROOT}/bin/llvm-rc"

DEP_SOURCE_DIR="${BUILD_DIR}/src/fdw_dependencies"
DEP_BUILD_DIR="${BUILD_DIR}/build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"
TOOLCHAIN_FILE="${BUILD_TOOLS}/cmake-toolchain.cmake"

mkdir -p "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS" "${SDK_PREFIX}/lib"
write_noop_ldconfig_wrapper "$BUILD_TOOLS"

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-clang" "${LLVM_ROOT}/bin/clang"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-clang"
fi
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-clang++" "${LLVM_ROOT}/bin/clang++"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-clang++"
fi
[[ -x "$CC" ]] || die "missing target C compiler: ${CC}"
[[ -x "$CXX" ]] || die "missing target C++ compiler: ${CXX}"

if [[ "$TARGET_KIND" == "mingw" ]]; then
  write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "$RC"
  RC="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
fi

COMMON_CPPFLAGS="${COMMON_CPPFLAGS:-} -I${SDK_PREFIX}/include"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="${COMMON_LDFLAGS:-} -L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_CFLAGS="${COMMON_CFLAGS} -fPIC"
  COMMON_CXXFLAGS="${COMMON_CXXFLAGS} -fPIC"
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -pthread -lm -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
else
  COMMON_CFLAGS="${COMMON_CFLAGS} -Wno-unused-command-line-argument"
  COMMON_CXXFLAGS="${COMMON_CXXFLAGS} -Wno-unused-command-line-argument"
fi

export CPPFLAGS="$COMMON_CPPFLAGS"
export LDFLAGS="$COMMON_LDFLAGS"
export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=
export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"

write_toolchain_file

UNIXODBC_ARCHIVE="unixODBC-${UNIXODBC_VERSION}.tar.gz"
FREETDS_ARCHIVE="freetds-${FREETDS_VERSION}.tar.bz2"
MARIADB_ARCHIVE="mariadb-connector-c-${MARIADB_VERSION}-src.tar.gz"
HIREDIS_ARCHIVE="hiredis-${HIREDIS_VERSION}.tar.gz"
MONGO_C_DRIVER_ARCHIVE="mongo-c-driver-${MONGO_C_DRIVER_VERSION}.tar.gz"

if [[ "$TARGET_KIND" == "linux" ]]; then
  download_archive "https://www.unixodbc.org/${UNIXODBC_ARCHIVE}" "$UNIXODBC_ARCHIVE"
fi
download_archive "https://github.com/FreeTDS/freetds/releases/download/v${FREETDS_VERSION}/${FREETDS_ARCHIVE}" "$FREETDS_ARCHIVE"
download_archive "https://dlm.mariadb.com/4751056/Connectors/c/connector-c-${MARIADB_VERSION}/${MARIADB_ARCHIVE}" "$MARIADB_ARCHIVE"
download_archive "https://github.com/redis/hiredis/archive/refs/tags/v${HIREDIS_VERSION}.tar.gz" "$HIREDIS_ARCHIVE"
download_archive "https://github.com/mongodb/mongo-c-driver/releases/download/${MONGO_C_DRIVER_VERSION}/${MONGO_C_DRIVER_ARCHIVE}" "$MONGO_C_DRIVER_ARCHIVE"

if [[ "$TARGET_KIND" == "linux" ]]; then
  extract_archive_source "${DEP_SOURCE_DIR}/unixodbc" "$UNIXODBC_ARCHIVE" "configure"
fi
extract_archive_source "${DEP_SOURCE_DIR}/freetds" "$FREETDS_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/mariadb-connector-c" "$MARIADB_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/hiredis" "$HIREDIS_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/mongo-c-driver" "$MONGO_C_DRIVER_ARCHIVE" "CMakeLists.txt"

log "Installing FDW dependencies into ${SDK_PREFIX}"
build_unixodbc
build_freetds
build_mariadb_connector_c
build_hiredis
build_mongo_c_driver
copy_mingw_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
rewrite_linux_absolute_needed
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_fdw_dependencies

render_template "${TEMPLATE_DIR}/README.fdw-dependencies.in" "${SDK_PREFIX}/README.fdw-dependencies" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "UNIXODBC_VERSION=${UNIXODBC_VERSION}" \
  "FREETDS_VERSION=${FREETDS_VERSION}" \
  "MARIADB_VERSION=${MARIADB_VERSION}" \
  "HIREDIS_VERSION=${HIREDIS_VERSION}" \
  "MONGO_C_DRIVER_VERSION=${MONGO_C_DRIVER_VERSION}"

log "FDW dependency package ready: ${SDK_PREFIX}"
