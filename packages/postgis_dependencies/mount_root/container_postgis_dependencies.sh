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
  local archive_marker="${source_dir}/.postgis-dependencies-source-archive"

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
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    configure_ld="$CC"
    libtool_cache_env+=(lt_cv_prog_gnu_ld=yes lt_cv_prog_gnu_ldcxx=yes)
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
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBS="${LIBS:-}" \
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
      -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
      -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
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

rewrite_dependency_prefixes() {
  local installed_file=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.cfg|*.conf|*.txt|*.md|*.sh|*.py|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    if grep -IqE "/opt/(gdal-${GDAL_VERSION}|cgal-${CGAL_VERSION}-sfcgal-${SFCGAL_VERSION})-${TARGET_TRIPLE}" "$installed_file"; then
      sed -i \
        -e "s#/opt/gdal-${GDAL_VERSION}-${TARGET_TRIPLE}#${SDK_PREFIX}#g" \
        -e "s#/opt/cgal-${CGAL_VERSION}-sfcgal-${SFCGAL_VERSION}-${TARGET_TRIPLE}#${SDK_PREFIX}#g" \
        "$installed_file"
    fi
  done < <(find "$SDK_PREFIX" -type f -print0 2>/dev/null)
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

copy_dependency_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib/pkgconfig" -type f -name '*static*.pc' -delete 2>/dev/null || true
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man" "${SDK_PREFIX}/share/info"
}

build_libmd() {
  configure_make_install libmd "${DEP_SOURCE_DIR}/libmd" \
    --enable-shared \
    --disable-static
}

build_libbsd() {
  configure_make_install libbsd "${DEP_SOURCE_DIR}/libbsd" \
    --enable-shared \
    --disable-static
}

build_qhull() {
  cmake_install qhull "${DEP_SOURCE_DIR}/qhull" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DLINK_APPS_SHARED=ON
}

resolve_qhull_archive() {
  case "$QHULL_VERSION" in
    2020.2|8.0.2)
      printf '%s\n' "qhull-2020-src-8.0.2.tgz"
      ;;
    *)
      die "unsupported Qhull version: ${QHULL_VERSION}"
      ;;
  esac
}

build_protobuf() {
  cmake_install protobuf "${DEP_SOURCE_DIR}/protobuf" \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_CONFORMANCE=OFF \
    -Dprotobuf_BUILD_EXAMPLES=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_LIBPROTOC=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=ON \
    -Dprotobuf_MSVC_STATIC_RUNTIME=OFF \
    -DABSL_PROPAGATE_CXX_STD=ON
}

build_protobuf_c() {
  configure_make_install protobuf-c "${DEP_SOURCE_DIR}/protobuf-c" \
    --enable-shared \
    --disable-static \
    --disable-protoc
}

validate_postgis_dependencies() {
  [[ -f "${SDK_PREFIX}/README.gdal" ]] || die "missing GDAL marker"
  [[ -f "${SDK_PREFIX}/README.cgal" ]] || die "missing CGAL marker"
  [[ -f "${SDK_PREFIX}/include/gdal.h" ]] || die "missing GDAL headers"
  [[ -f "${SDK_PREFIX}/include/SFCGAL/version.h" ]] || die "missing SFCGAL headers"
  [[ -f "${SDK_PREFIX}/include/bsd/stdlib.h" || "$TARGET_KIND" == "mingw" ]] || die "missing libbsd headers"
  [[ -f "${SDK_PREFIX}/include/qhull_ra.h" || -f "${SDK_PREFIX}/include/libqhull_r/qhull_ra.h" ]] || die "missing Qhull headers"
  [[ -f "${SDK_PREFIX}/include/google/protobuf/message.h" ]] || die "missing protobuf headers"
  [[ -f "${SDK_PREFIX}/include/protobuf-c/protobuf-c.h" ]] || die "missing protobuf-c headers"
  [[ -f "${SDK_PREFIX}/lib/pkgconfig/libprotobuf-c.pc" ]] || die "missing protobuf-c pkg-config file"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*protobuf-c*.dll' -o -name '*protobuf-c*.dll.a' \) | grep -q . || die "missing protobuf-c DLL/import library"
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*qhull_r*.dll' -o -name '*qhull_r*.dll.a' \) | grep -q . || die "missing Qhull DLL/import library"
    return 0
  fi

  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libbsd.so*' | grep -q . || die "missing libbsd shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libqhull_r.so*' | grep -q . || die "missing Qhull shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libprotobuf.so*' | grep -q . || die "missing protobuf shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libprotobuf-c.so*' | grep -q . || die "missing protobuf-c shared library"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/postgis_dependencies-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

LIBMD_VERSION="${LIBMD_VERSION:-1.2.0}"
LIBBSD_VERSION="${LIBBSD_VERSION:-0.12.2}"
QHULL_VERSION="${QHULL_VERSION:-2020.2}"
PROTOBUF_VERSION="${PROTOBUF_VERSION:-21.0}"
PROTOBUF_C_VERSION="${PROTOBUF_C_VERSION:-1.5.2}"
GDAL_VERSION="${GDAL_VERSION:-3.13.1}"
CGAL_VERSION="${CGAL_VERSION:-5.6.3}"
SFCGAL_VERSION="${SFCGAL_VERSION:-1.5.2}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing PostGIS dependency prefix: ${SDK_PREFIX}"
[[ -f "${SDK_PREFIX}/README.gdal" ]] || die "missing GDAL marker: ${SDK_PREFIX}/README.gdal"
[[ -f "${SDK_PREFIX}/README.cgal" ]] || die "missing CGAL marker: ${SDK_PREFIX}/README.cgal"

require_command curl
require_command tar
require_command make
require_command cmake
require_command ninja
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
  CONFIGURE_BUILD_TRIPLE="${ARCH}-postgisdepsbuild-linux-gnu"
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

DEP_SOURCE_DIR="${BUILD_DIR}/src/postgis_dependencies"
DEP_BUILD_DIR="${BUILD_DIR}/build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
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
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
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
rewrite_dependency_prefixes

LIBMD_ARCHIVE="libmd-${LIBMD_VERSION}.tar.xz"
LIBBSD_ARCHIVE="libbsd-${LIBBSD_VERSION}.tar.xz"
QHULL_ARCHIVE="$(resolve_qhull_archive)"
PROTOBUF_ARCHIVE="protobuf-all-${PROTOBUF_VERSION}.tar.gz"
PROTOBUF_C_ARCHIVE="protobuf-c-${PROTOBUF_C_VERSION}.tar.gz"

download_archive "https://archive.hadrons.org/software/libmd/${LIBMD_ARCHIVE}" "$LIBMD_ARCHIVE"
download_archive "https://libbsd.freedesktop.org/releases/${LIBBSD_ARCHIVE}" "$LIBBSD_ARCHIVE"
download_archive "http://www.qhull.org/download/${QHULL_ARCHIVE}" "$QHULL_ARCHIVE"
download_archive "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/${PROTOBUF_ARCHIVE}" "$PROTOBUF_ARCHIVE"
download_archive "https://github.com/protobuf-c/protobuf-c/releases/download/v${PROTOBUF_C_VERSION}/${PROTOBUF_C_ARCHIVE}" "$PROTOBUF_C_ARCHIVE"

extract_archive_source "${DEP_SOURCE_DIR}/libmd" "$LIBMD_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libbsd" "$LIBBSD_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/qhull" "$QHULL_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/protobuf" "$PROTOBUF_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/protobuf-c" "$PROTOBUF_C_ARCHIVE" "configure"

log "Installing PostGIS dependencies into ${SDK_PREFIX}"
if [[ "$TARGET_KIND" != "mingw" ]]; then
  build_libmd
  build_libbsd
fi
build_qhull
build_protobuf
build_protobuf_c
copy_dependency_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
rewrite_linux_absolute_needed
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_postgis_dependencies

render_template "${TEMPLATE_DIR}/README.postgis-dependencies.in" "${SDK_PREFIX}/README.postgis-dependencies" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "GDAL_VERSION=${GDAL_VERSION}" \
  "CGAL_VERSION=${CGAL_VERSION}" \
  "SFCGAL_VERSION=${SFCGAL_VERSION}" \
  "LIBMD_VERSION=${LIBMD_VERSION}" \
  "LIBBSD_VERSION=${LIBBSD_VERSION}" \
  "QHULL_VERSION=${QHULL_VERSION}" \
  "PROTOBUF_VERSION=${PROTOBUF_VERSION}" \
  "PROTOBUF_C_VERSION=${PROTOBUF_C_VERSION}"

log "PostGIS dependency package ready: ${SDK_PREFIX}"
