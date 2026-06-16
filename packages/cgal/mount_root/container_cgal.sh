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
  local archive_marker="${source_dir}/.cgal-source-archive"

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
    "RC_FLAGS=${RC_FLAGS}"
  chmod +x "$wrapper_path"
}

write_lib_wrapper() {
  local wrapper_path="$1"

  render_template "${TEMPLATE_DIR}/llvm-lib-wrapper.in" "$wrapper_path" \
    "LLVM_AR=${LLVM_ROOT}/bin/llvm-ar" \
    "LLVM_RANLIB=${LLVM_ROOT}/bin/llvm-ranlib"
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
  local abi_env=()
  local libtool_cache_env=()
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  if [[ "$ARCH" == "x86_64" ]]; then
    abi_env+=(ABI=64)
  fi

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    configure_ld="$CC"
    libtool_cache_env+=(lt_cv_prog_gnu_ld=yes lt_cv_prog_gnu_ldcxx=yes)
  fi

  log "Configuring dependency: ${package_name}"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    env \
      "${abi_env[@]}" \
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

rewrite_boost_prefixes() {
  local installed_file=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.cmake|*.pc|*.la|*.cfg|*.conf|*.txt|*.md|*/bin/*-config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    if grep -IqE "/opt/boost-${BOOST_VERSION}-${TARGET_TRIPLE}" "$installed_file"; then
      sed -i "s#/opt/boost-${BOOST_VERSION}-${TARGET_TRIPLE}#${SDK_PREFIX}#g" "$installed_file"
    fi
  done < <(find "$SDK_PREFIX" -type f -print0 2>/dev/null)
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

create_mingw_import_library() {
  local package_name="$1"
  local library_stem="$2"
  local dll_name="$3"
  local def_file=""
  local import_library="${SDK_PREFIX}/lib/${library_stem}.dll.a"

  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  [[ -f "$import_library" ]] && return 0
  def_file="$(
    find "${DEP_BUILD_DIR}/${package_name}" -path '*/.libs/*' -name "${library_stem}-*.dll.def" -type f \
      | sort \
      | head -n 1
  )"
  [[ -f "$def_file" ]] || die "missing ${library_stem} export definition: ${def_file}"
  "$DLLTOOL" -m i386:x86-64 -d "$def_file" -D "$dll_name" -l "$import_library"
  [[ -f "$import_library" ]] || die "failed to create ${library_stem} import library"
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man" "${SDK_PREFIX}/share/info"
}

build_gmp() {
  local gmp_args=(
    --enable-shared \
    --disable-static
  )
  local gmp_cflags="${CFLAGS:-}"
  local gmp_cxxflags="${CXXFLAGS:-}"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    gmp_args+=(--disable-cxx)
  else
    gmp_args+=(--enable-cxx)
  fi

  if [[ "$ARCH" == "loongarch64" ]]; then
    gmp_cflags="${gmp_cflags} -D__int128__=__int128"
    gmp_cxxflags="${gmp_cxxflags} -D__int128__=__int128"
  fi

  CFLAGS="$gmp_cflags" CXXFLAGS="$gmp_cxxflags" \
    configure_make_install gmp "${DEP_SOURCE_DIR}/gmp" "${gmp_args[@]}"
  create_mingw_import_library gmp libgmp libgmp-10.dll
}

build_mpfr() {
  configure_make_install mpfr "${DEP_SOURCE_DIR}/mpfr" \
    --enable-shared \
    --disable-static \
    "--with-gmp=${SDK_PREFIX}"
  create_mingw_import_library mpfr libmpfr libmpfr-6.dll
}

build_cgal() {
  local gmpxx_args=()

  if [[ -n "$GMPXX_LIBRARY" && -f "$GMPXX_LIBRARY" ]]; then
    gmpxx_args+=("-DGMPXX_LIBRARIES=${GMPXX_LIBRARY}")
  fi

  cmake_install cgal "${DEP_SOURCE_DIR}/cgal" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DCGAL_BUILD_TESTING=OFF \
    -DCGAL_BUILD_EXAMPLES=OFF \
    -DCGAL_BUILD_DEMOS=OFF \
    "-DBOOST_ROOT=${SDK_PREFIX}" \
    "-DBoost_ROOT=${SDK_PREFIX}" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    "-DGMP_INCLUDE_DIR=${SDK_PREFIX}/include" \
    "-DGMP_LIBRARIES=${GMP_LIBRARY}" \
    "${gmpxx_args[@]}" \
    "-DMPFR_INCLUDE_DIR=${SDK_PREFIX}/include" \
    "-DMPFR_LIBRARIES=${MPFR_LIBRARY}"
}

build_sfcgal() {
  local gmpxx_args=()

  if [[ -n "$GMPXX_LIBRARY" && -f "$GMPXX_LIBRARY" ]]; then
    gmpxx_args+=("-DGMPXX_LIBRARIES=${GMPXX_LIBRARY}")
  fi

  cmake_install sfcgal "${DEP_SOURCE_DIR}/sfcgal" \
    -DBUILD_SHARED_LIBS=ON \
    -DSFCGAL_BUILD_TESTS=OFF \
    -DSFCGAL_BUILD_EXAMPLES=OFF \
    -DSFCGAL_BUILD_VIEWER=OFF \
    -DSFCGAL_BUILD_OSG=OFF \
    "-DBOOST_ROOT=${SDK_PREFIX}" \
    "-DBoost_ROOT=${SDK_PREFIX}" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    "-DCGAL_DIR=${SDK_PREFIX}/lib/cmake/CGAL" \
    "-DGMP_INCLUDE_DIR=${SDK_PREFIX}/include" \
    "-DGMP_LIBRARIES=${GMP_LIBRARY}" \
    "${gmpxx_args[@]}" \
    "-DMPFR_INCLUDE_DIR=${SDK_PREFIX}/include" \
    "-DMPFR_LIBRARIES=${MPFR_LIBRARY}"
}

validate_cgal() {
  [[ -f "${SDK_PREFIX}/include/gmp.h" ]] || die "missing GMP headers"
  [[ -f "${SDK_PREFIX}/include/mpfr.h" ]] || die "missing MPFR headers"
  [[ -f "${SDK_PREFIX}/include/CGAL/version.h" ]] || die "missing CGAL headers"
  [[ -d "${SDK_PREFIX}/lib/cmake/CGAL" ]] || die "missing CGAL CMake package"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*SFCGAL*.dll' -o -name '*SFCGAL*.dll.a' -o -name 'libsfcgal*.dll' -o -name 'libsfcgal*.dll.a' \) | grep -q . || die "missing SFCGAL DLL/import library"
    return 0
  fi

  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libSFCGAL.so*' | grep -q . || \
    find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libsfcgal.so*' | grep -q . || \
    die "missing SFCGAL shared library"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
BOOST_VERSION="${BOOST_VERSION:-1.84.0}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"
MPFR_VERSION="${MPFR_VERSION:-4.2.2}"
CGAL_VERSION="${CGAL_VERSION:-5.6.3}"
SFCGAL_VERSION="${SFCGAL_VERSION:-1.5.2}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/cgal-${CGAL_VERSION}-sfcgal-${SFCGAL_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing CGAL package prefix: ${SDK_PREFIX}"
[[ -f "${SDK_PREFIX}/README.boost" ]] || die "missing Boost marker: ${SDK_PREFIX}/README.boost"

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
  CONFIGURE_BUILD_TRIPLE="${ARCH}-cgalbuild-linux-gnu"
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

DEP_SOURCE_DIR="${BUILD_DIR}/src/cgal"
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
  write_lib_wrapper "${BUILD_TOOLS}/lib"
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
rewrite_boost_prefixes

GMP_LIBRARY="${SDK_PREFIX}/lib/libgmp.so"
GMPXX_LIBRARY="${SDK_PREFIX}/lib/libgmpxx.so"
MPFR_LIBRARY="${SDK_PREFIX}/lib/libmpfr.so"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  GMP_LIBRARY="${SDK_PREFIX}/lib/libgmp.dll.a"
  GMPXX_LIBRARY=""
  MPFR_LIBRARY="${SDK_PREFIX}/lib/libmpfr.dll.a"
fi

GMP_ARCHIVE="gmp-${GMP_VERSION}.tar.xz"
MPFR_ARCHIVE="mpfr-${MPFR_VERSION}.tar.xz"
CGAL_ARCHIVE="CGAL-${CGAL_VERSION}.tar.xz"
SFCGAL_ARCHIVE="SFCGAL-v${SFCGAL_VERSION}.tar.bz2"

download_archive "https://ftp.gnu.org/gnu/gmp/${GMP_ARCHIVE}" "$GMP_ARCHIVE"
download_archive "https://ftp.gnu.org/gnu/mpfr/${MPFR_ARCHIVE}" "$MPFR_ARCHIVE"
download_archive "https://github.com/CGAL/cgal/releases/download/v${CGAL_VERSION}/${CGAL_ARCHIVE}" "$CGAL_ARCHIVE"
download_archive "https://gitlab.com/sfcgal/SFCGAL/-/archive/v${SFCGAL_VERSION}/${SFCGAL_ARCHIVE}" "$SFCGAL_ARCHIVE"

extract_archive_source "${DEP_SOURCE_DIR}/gmp" "$GMP_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/mpfr" "$MPFR_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/cgal" "$CGAL_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/sfcgal" "$SFCGAL_ARCHIVE" "CMakeLists.txt"

log "Installing CGAL/SFCGAL dependencies into ${SDK_PREFIX}"
build_gmp
build_mpfr
build_cgal
build_sfcgal
copy_dependency_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_cgal

render_template "${TEMPLATE_DIR}/README.cgal.in" "${SDK_PREFIX}/README.cgal" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "BOOST_VERSION=${BOOST_VERSION}" \
  "GMP_VERSION=${GMP_VERSION}" \
  "MPFR_VERSION=${MPFR_VERSION}" \
  "CGAL_VERSION=${CGAL_VERSION}" \
  "SFCGAL_VERSION=${SFCGAL_VERSION}"

log "CGAL/SFCGAL package ready: ${SDK_PREFIX}"
