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

extract_zip_source() {
  local source_dir="$1"
  local archive_name="$2"
  local marker_path="$3"
  local tmp_dir="${source_dir}.extract"
  local extracted_dir=""
  local archive_marker="${source_dir}/.source-archive"

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

write_meson_cross_file() {
  render_template "${TEMPLATE_DIR}/meson-cross.ini.in" "$MESON_CROSS_FILE" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "STRIP=${STRIP}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}" \
    "MESON_SYSTEM=${MESON_SYSTEM}" \
    "MESON_CPU_FAMILY=${MESON_CPU_FAMILY}" \
    "MESON_CPU=${MESON_CPU}" \
    "MESON_EXTRA_C_ARGS=${MESON_EXTRA_C_ARGS}"
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

meson_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  local stage_dir="${package_build_dir}/stage"
  rm -rf "$package_build_dir"

  log "Configuring dependency: ${package_name}"
  env \
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
    PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR= \
    meson setup "$package_build_dir" "$source_dir" \
      --cross-file="$MESON_CROSS_FILE" \
      --prefix="$SDK_PREFIX" \
      --libdir=lib \
      --buildtype=release \
      "$@"

  log "Building dependency: ${package_name}"
  LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    meson compile -C "$package_build_dir" -j "$JOBS"
  DESTDIR="$stage_dir" \
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    meson install -C "$package_build_dir"
  cp -a "${stage_dir}${SDK_PREFIX}/." "$SDK_PREFIX/"
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name '*.la' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name '*.a' ! -name '*.dll.a' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib/pkgconfig" -type f -name '*static*.pc' -delete 2>/dev/null || true
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man" "${SDK_PREFIX}/share/info"
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

build_freetype() {
  cmake_install freetype "${DEP_SOURCE_DIR}/freetype" \
    -DBUILD_SHARED_LIBS=ON \
    -DFT_DISABLE_ZLIB=TRUE \
    -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_PNG=TRUE \
    -DFT_DISABLE_HARFBUZZ=TRUE \
    -DFT_DISABLE_BROTLI=TRUE
}

build_fontconfig() {
  meson_install fontconfig "${DEP_SOURCE_DIR}/fontconfig" \
    --wrap-mode=nodownload \
    --default-library=shared \
    -Ddoc=disabled \
    -Ddoc-txt=disabled \
    -Ddoc-man=disabled \
    -Ddoc-pdf=disabled \
    -Ddoc-html=disabled \
    -Dnls=disabled \
    -Dtests=disabled \
    -Dtools=disabled \
    -Dcache-build=disabled \
    -Diconv=disabled \
    -Dxml-backend=expat \
    -Dfontations=disabled
}

build_host_gperf() {
  local source_dir="${DEP_SOURCE_DIR}/gperf"
  local build_dir="${DEP_BUILD_DIR}/gperf-host"
  local prefix="${BUILD_TOOLS}/gperf"
  local host_cppflags="-I${build_dir}/lib -I${build_dir}/src -I${source_dir}/lib -I${source_dir}/src"

  rm -rf "$build_dir" "$prefix"
  mkdir -p "$build_dir"

  log "Configuring build tool: gperf"
  (
    cd "$build_dir"
    env \
      CC="$BUILD_CC" \
      CXX="$BUILD_CXX" \
      AR="${LLVM_ROOT}/bin/llvm-ar" \
      RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
      CPPFLAGS="$host_cppflags" \
      CFLAGS="-O2" \
      CXXFLAGS="-O2 -std=gnu++11" \
      LDFLAGS= \
      "${source_dir}/configure" \
        --prefix="$prefix"
    make -j "$JOBS" CPPFLAGS="$host_cppflags" CFLAGS="-O2" CXXFLAGS="-O2 -std=gnu++11" LDFLAGS=
    make install CPPFLAGS="$host_cppflags" CFLAGS="-O2" CXXFLAGS="-O2 -std=gnu++11" LDFLAGS=
  )
}

require_glob() {
  local pattern="$1"

  compgen -G "$pattern" >/dev/null || die "missing expected file: ${pattern}"
}

validate_fontconfig_package() {
  [[ -f "${SDK_PREFIX}/include/expat.h" ]] || die "missing expat headers"
  [[ -f "${SDK_PREFIX}/include/freetype2/ft2build.h" ]] || die "missing FreeType headers"
  [[ -f "${SDK_PREFIX}/include/fontconfig/fontconfig.h" ]] || die "missing fontconfig headers"
  [[ -f "${SDK_PREFIX}/lib/pkgconfig/expat.pc" ]] || die "missing expat pkg-config file"
  [[ -f "${SDK_PREFIX}/lib/pkgconfig/freetype2.pc" ]] || die "missing FreeType pkg-config file"
  [[ -f "${SDK_PREFIX}/lib/pkgconfig/fontconfig.pc" ]] || die "missing fontconfig pkg-config file"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    require_glob "${SDK_PREFIX}/bin/*expat*.dll"
    require_glob "${SDK_PREFIX}/bin/*freetype*.dll"
    require_glob "${SDK_PREFIX}/bin/*fontconfig*.dll"
    require_glob "${SDK_PREFIX}/lib/*expat*.dll.a"
    require_glob "${SDK_PREFIX}/lib/*freetype*.dll.a"
    require_glob "${SDK_PREFIX}/lib/*fontconfig*.dll.a"
    return 0
  fi

  require_glob "${SDK_PREFIX}/lib/libexpat.so*"
  require_glob "${SDK_PREFIX}/lib/libfreetype.so*"
  require_glob "${SDK_PREFIX}/lib/libfontconfig.so*"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/fontconfig-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

FONTCONFIG_VERSION="${FONTCONFIG_VERSION:-2.16.0}"
FREETYPE_VERSION="${FREETYPE_VERSION:-2.14.2}"
GPERF_VERSION="${GPERF_VERSION:-3.1}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing fontconfig dependency prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make
require_command cmake
require_command ninja
require_command meson
require_command python3
require_command pkg-config

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CMAKE_SYSTEM_NAME="Linux"
    MESON_SYSTEM="linux"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    RC_FLAGS="${RC_FLAGS:-}"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CMAKE_SYSTEM_NAME="Windows"
    MESON_SYSTEM="windows"
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
  x86_64)
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
    ;;
  aarch64)
    CMAKE_SYSTEM_PROCESSOR="aarch64"
    MESON_CPU_FAMILY="aarch64"
    MESON_CPU="aarch64"
    ;;
  riscv64)
    CMAKE_SYSTEM_PROCESSOR="riscv64"
    MESON_CPU_FAMILY="riscv64"
    MESON_CPU="riscv64"
    ;;
  loongarch64)
    CMAKE_SYSTEM_PROCESSOR="loongarch64"
    MESON_CPU_FAMILY="loongarch64"
    MESON_CPU="loongarch64"
    ;;
  *) die "unsupported ARCH: ${ARCH}" ;;
esac

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
[[ -x "$RC" ]] || RC="${LLVM_ROOT}/bin/llvm-rc"

DEP_SOURCE_DIR="${BUILD_DIR}/src/fontconfig"
DEP_BUILD_DIR="${BUILD_DIR}/build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
TOOLCHAIN_FILE="${BUILD_TOOLS}/cmake-toolchain.cmake"
MESON_CROSS_FILE="${BUILD_TOOLS}/meson-cross.ini"

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
COMMON_LDFLAGS="${COMMON_LDFLAGS:-} -fuse-ld=lld -L${SDK_PREFIX}/lib"
MESON_EXTRA_C_ARGS=", '-Qunused-arguments'"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_CFLAGS="${COMMON_CFLAGS} -fPIC"
  COMMON_CXXFLAGS="${COMMON_CXXFLAGS} -fPIC"
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -pthread -lm -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
else
  COMMON_CFLAGS="${COMMON_CFLAGS} -Wno-unused-command-line-argument"
  COMMON_CXXFLAGS="${COMMON_CXXFLAGS} -Wno-unused-command-line-argument"
  MESON_EXTRA_C_ARGS=", '-Qunused-arguments', '-Wno-unused-command-line-argument'"
fi

export CPPFLAGS="$COMMON_CPPFLAGS"
export LDFLAGS="$COMMON_LDFLAGS"
export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=
export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"

write_toolchain_file
write_meson_cross_file

FREETYPE_ARCHIVE="ft${FREETYPE_VERSION//./}.zip"
FONTCONFIG_ARCHIVE="fontconfig-${FONTCONFIG_VERSION}.tar.xz"
GPERF_ARCHIVE="gperf-${GPERF_VERSION}.tar.gz"

download_archive "https://download.savannah.gnu.org/releases/freetype/${FREETYPE_ARCHIVE}" "$FREETYPE_ARCHIVE"
download_archive "https://www.freedesktop.org/software/fontconfig/release/${FONTCONFIG_ARCHIVE}" "$FONTCONFIG_ARCHIVE"
download_archive "https://ftp.gnu.org/pub/gnu/gperf/${GPERF_ARCHIVE}" "$GPERF_ARCHIVE"

extract_zip_source "${DEP_SOURCE_DIR}/freetype" "$FREETYPE_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/fontconfig" "$FONTCONFIG_ARCHIVE" "meson.build"
extract_archive_source "${DEP_SOURCE_DIR}/gperf" "$GPERF_ARCHIVE" "configure"

log "Installing fontconfig dependencies into ${SDK_PREFIX}"
build_host_gperf
export PATH="${BUILD_TOOLS}/gperf/bin:${PATH}"
build_freetype
build_fontconfig
copy_mingw_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
rewrite_linux_absolute_needed
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_fontconfig_package

render_template "${TEMPLATE_DIR}/README.fontconfig.in" "${SDK_PREFIX}/README.fontconfig" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "FONTCONFIG_VERSION=${FONTCONFIG_VERSION}" \
  "FREETYPE_VERSION=${FREETYPE_VERSION}" \
  "GPERF_VERSION=${GPERF_VERSION}"

log "fontconfig package ready: ${SDK_PREFIX}"
