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
  local archive_marker="${source_dir}/.image-source-archive"

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
  env \
    PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
    PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR= \
    cmake -S "$source_dir" -B "$package_build_dir" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
      -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
      -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
      -DCMAKE_MODULE_LINKER_FLAGS="$COMMON_LDFLAGS" \
      "${cmake_target_args[@]}" \
      "$@"

  log "Building dependency: ${package_name}"
  cmake --build "$package_build_dir" --parallel "$JOBS"
  cmake --install "$package_build_dir"
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete 2>/dev/null || true
}

copy_dependency_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
}

build_libjpeg_turbo() {
  cmake_install libjpeg-turbo "${DEP_SOURCE_DIR}/libjpeg-turbo" \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=OFF \
    -DWITH_SIMD=OFF \
    -DWITH_JPEG8=ON \
    -DWITH_TURBOJPEG=ON \
    -DWITH_TOOLS=OFF \
    -DWITH_TESTS=OFF \
    -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_LIBDIR=lib
}

build_libpng() {
  cmake_install libpng "${DEP_SOURCE_DIR}/libpng" \
    -DPNG_SHARED=ON \
    -DPNG_STATIC=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF \
    -DPNG_FRAMEWORK=OFF \
    -DZLIB_ROOT="$SDK_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib
}

build_libtiff() {
  cmake_install libtiff "${DEP_SOURCE_DIR}/libtiff" \
    -DBUILD_SHARED_LIBS=ON \
    -Dtiff-tools=OFF \
    -Dtiff-tests=OFF \
    -Dtiff-contrib=OFF \
    -Dtiff-docs=OFF \
    -Dtiff-deprecated=OFF \
    -Dtiff-install=ON \
    -Dld-version-script=OFF \
    -Djbig=OFF \
    -Djpeg=ON \
    -Djpeg12=OFF \
    -Dlibdeflate=OFF \
    -Dlzma=ON \
    -Dold-jpeg=OFF \
    -Dpixarlog=ON \
    -Dwebp=OFF \
    -Dzstd=ON \
    -DZLIB_ROOT="$SDK_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib
}

validate_image() {
  [[ -f "${SDK_PREFIX}/include/jpeglib.h" ]] || die "missing libjpeg-turbo headers"
  [[ -f "${SDK_PREFIX}/include/png.h" ]] || die "missing libpng headers"
  [[ -f "${SDK_PREFIX}/include/tiff.h" ]] || die "missing libtiff headers"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*jpeg*.dll' -o -name '*jpeg*.dll.a' \) | grep -q . || die "missing JPEG DLL/import library"
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*png*.dll' -o -name '*png*.dll.a' \) | grep -q . || die "missing PNG DLL/import library"
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*tiff*.dll' -o -name '*tiff*.dll.a' \) | grep -q . || die "missing TIFF DLL/import library"
    return 0
  fi

  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libjpeg.so*' | grep -q . || die "missing libjpeg shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libpng*.so*' | grep -q . || die "missing libpng shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libtiff.so*' | grep -q . || die "missing libtiff shared library"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/image-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

LIBJPEG_TURBO_VERSION="${LIBJPEG_TURBO_VERSION:-3.1.4.1}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.58}"
LIBTIFF_VERSION="${LIBTIFF_VERSION:-4.7.1}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing image package prefix: ${SDK_PREFIX}"
[[ -f "${SDK_PREFIX}/README.postgresql-dependencies" ]] || die "missing base marker: ${SDK_PREFIX}/README.postgresql-dependencies"

require_command curl
require_command tar
require_command cmake
require_command ninja

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="${TARGET_ROOT:-${SYSROOT}}"
    CMAKE_SYSTEM_NAME="Linux"
    COMMON_CFLAGS="${COMMON_CFLAGS:-} -fPIC"
    COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-} -fPIC"
    COMMON_LDFLAGS="${COMMON_LDFLAGS:-} -L${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CMAKE_SYSTEM_NAME="Windows"
    WINDRES_TARGET="${WINDRES_TARGET:-pe-x86-64}"
    MINGW_INCLUDE_DIR="${MINGW_INCLUDE_DIR:-${SYSROOT}/usr/${TARGET_TRIPLE}/include}"
    [[ -d "$MINGW_INCLUDE_DIR" ]] || die "missing MinGW include directory: ${MINGW_INCLUDE_DIR}"
    COMMON_CFLAGS="${COMMON_CFLAGS:-} -Wno-unused-command-line-argument"
    COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-} -Wno-unused-command-line-argument"
    COMMON_LDFLAGS="${COMMON_LDFLAGS:-} -L${SDK_PREFIX}/lib"
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

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
BUILD_CXX="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
LD="${LD:-${LLVM_ROOT}/bin/ld.lld}"
NM="${NM:-${LLVM_ROOT}/bin/llvm-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/llvm-objcopy}"
OBJDUMP="${OBJDUMP:-${LLVM_ROOT}/bin/llvm-objdump}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/llvm-strip}"
DLLTOOL="${DLLTOOL:-${LLVM_ROOT}/bin/llvm-dlltool}"
RC_FLAGS="${RC_FLAGS:-}"

[[ -x "$BUILD_CC" ]] || die "missing build compiler: ${BUILD_CC}"
[[ -x "$BUILD_CXX" ]] || die "missing build C++ compiler: ${BUILD_CXX}"
[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$AR" ]] || die "missing archiver: ${AR}"
[[ -x "$LD" ]] || die "missing linker: ${LD}"
[[ -x "$NM" ]] || die "missing nm: ${NM}"
[[ -x "$OBJCOPY" ]] || die "missing objcopy: ${OBJCOPY}"
[[ -x "$OBJDUMP" ]] || die "missing objdump: ${OBJDUMP}"
[[ -x "$RANLIB" ]] || die "missing ranlib: ${RANLIB}"
[[ -x "$STRIP" ]] || die "missing strip: ${STRIP}"

SOURCE_ROOT="${BUILD_DIR}/src"
DEP_SOURCE_DIR="${SOURCE_ROOT}/image"
DEP_BUILD_DIR="${BUILD_DIR}/build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
TOOLCHAIN_FILE="${BUILD_TOOLS}/cmake-toolchain.cmake"

mkdir -p "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS" "${SDK_PREFIX}/lib"

if [[ "$TARGET_KIND" == "mingw" ]]; then
  CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
  CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
else
  CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang}"
  CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang++}"
fi
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

RC="${RC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-windres}"
if [[ "$TARGET_KIND" == "mingw" && ! -x "$RC" ]]; then
  if [[ -x "${LLVM_ROOT}/bin/llvm-windres" ]]; then
    write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "${LLVM_ROOT}/bin/llvm-windres"
    RC="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
  elif [[ -x "${LLVM_ROOT}/bin/llvm-rc" ]]; then
    RC="${LLVM_ROOT}/bin/llvm-rc"
  else
    die "missing windres/rc for MinGW target"
  fi
fi
if [[ "$TARGET_KIND" == "linux" && ! -x "$RC" ]]; then
  RC="${CMAKE_RC_COMPILER:-}"
fi

COMMON_CPPFLAGS="${COMMON_CPPFLAGS:-} -I${SDK_PREFIX}/include"
export CPPFLAGS="$COMMON_CPPFLAGS"
export LDFLAGS="$COMMON_LDFLAGS"
export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=
export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"

write_toolchain_file

LIBJPEG_TURBO_ARCHIVE="libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz"
LIBPNG_ARCHIVE="libpng-${LIBPNG_VERSION}.tar.xz"
LIBTIFF_ARCHIVE="tiff-${LIBTIFF_VERSION}.tar.xz"

download_archive \
  "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VERSION}/${LIBJPEG_TURBO_ARCHIVE}" \
  "$LIBJPEG_TURBO_ARCHIVE"
download_archive \
  "https://prdownloads.sourceforge.net/libpng/${LIBPNG_ARCHIVE}" \
  "$LIBPNG_ARCHIVE"
download_archive \
  "https://download.osgeo.org/libtiff/${LIBTIFF_ARCHIVE}" \
  "$LIBTIFF_ARCHIVE"

extract_archive_source "${DEP_SOURCE_DIR}/libjpeg-turbo" "$LIBJPEG_TURBO_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/libpng" "$LIBPNG_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/libtiff" "$LIBTIFF_ARCHIVE" "CMakeLists.txt"

log "Installing image dependencies into ${SDK_PREFIX}"
build_libjpeg_turbo
build_libpng
build_libtiff
copy_dependency_dlls_to_bin
remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_image

render_template "${TEMPLATE_DIR}/README.image.in" "${SDK_PREFIX}/README.image" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "LIBJPEG_TURBO_VERSION=${LIBJPEG_TURBO_VERSION}" \
  "LIBPNG_VERSION=${LIBPNG_VERSION}" \
  "LIBTIFF_VERSION=${LIBTIFF_VERSION}"

log "image package ready: ${SDK_PREFIX}"
