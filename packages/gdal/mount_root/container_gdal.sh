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
  local archive_marker="${source_dir}/.gdal-source-archive"

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

apply_source_patch_once() {
  local source_dir="$1"
  local patch_path="$2"
  local patch_name=""

  patch_name="$(basename "$patch_path")"
  if [[ ! -f "${source_dir}/.patched-${patch_name}" ]]; then
    (
      cd "$source_dir"
      patch -p1 -i "$patch_path"
    )
    touch "${source_dir}/.patched-${patch_name}"
  fi
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
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring dependency: ${package_name}"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
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
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man" "${SDK_PREFIX}/share/info"
}

rewrite_dependency_prefixes() {
  local installed_file=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.py|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    if grep -IqE "/opt/(postgresql_dependencies(-18)?|image)-${TARGET_TRIPLE}" "$installed_file"; then
      sed -i \
        -e "s#/opt/postgresql_dependencies-18-${TARGET_TRIPLE}#${SDK_PREFIX}#g" \
        -e "s#/opt/postgresql_dependencies-${TARGET_TRIPLE}#${SDK_PREFIX}#g" \
        -e "s#/opt/image-${TARGET_TRIPLE}#${SDK_PREFIX}#g" \
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

build_geos() {
  cmake_install geos "${DEP_SOURCE_DIR}/geos" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DGEOS_BUILD_DEVELOPER=OFF \
    -DGEOS_ENABLE_TESTS=OFF
}

build_libyaml() {
  configure_make_install libyaml "${DEP_SOURCE_DIR}/libyaml" \
    --enable-shared \
    --disable-static
}

build_proj() {
  cmake_install proj "${DEP_SOURCE_DIR}/proj" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_APPS=OFF \
    -DENABLE_CURL=ON \
    -DENABLE_TIFF=ON \
    -DENABLE_IPO=OFF \
    -DUSE_EXTERNAL_GTEST=OFF \
    -DSQLITE3_INCLUDE_DIR="${SDK_PREFIX}/include" \
    -DSQLITE3_LIBRARY="${SQLITE3_LIBRARY}" \
    -DCURL_INCLUDE_DIR="${SDK_PREFIX}/include" \
    -DCURL_LIBRARY="${CURL_LIBRARY}" \
    -DTIFF_INCLUDE_DIR="${SDK_PREFIX}/include" \
    -DTIFF_LIBRARY="${TIFF_LIBRARY}"
}

build_libgeotiff() {
  cmake_install libgeotiff "${DEP_SOURCE_DIR}/libgeotiff" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DWITH_TIFF=ON \
    -DWITH_PROJ=ON \
    -DWITH_ZLIB=ON \
    -DTIFF_INCLUDE_DIR="${SDK_PREFIX}/include" \
    -DTIFF_LIBRARY="${TIFF_LIBRARY}" \
    -DPROJ_INCLUDE_DIR="${SDK_PREFIX}/include" \
    -DPROJ_LIBRARY="${PROJ_LIBRARY}" \
    -DZLIB_ROOT="$SDK_PREFIX"
}

build_minizip() {
  cmake_install minizip "${DEP_SOURCE_DIR}/zlib/contrib/minizip" \
    -DMINIZIP_BUILD_SHARED=ON \
    -DMINIZIP_BUILD_STATIC=OFF \
    -DMINIZIP_BUILD_TESTING=OFF \
    -DMINIZIP_ENABLE_BZIP2=OFF \
    -DMINIZIP_INSTALL=ON \
    -DZLIB_ROOT="$SDK_PREFIX"

  mkdir -p "${SDK_PREFIX}/include/minizip"
  cp -a \
    "${SDK_PREFIX}/include/crypt.h" \
    "${SDK_PREFIX}/include/ints.h" \
    "${SDK_PREFIX}/include/ioapi.h" \
    "${SDK_PREFIX}/include/mztools.h" \
    "${SDK_PREFIX}/include/unzip.h" \
    "${SDK_PREFIX}/include/zip.h" \
    "${SDK_PREFIX}/include/minizip/"
}

build_freexl() {
  LIBS="-liconv ${LIBS:-}" configure_make_install freexl "${DEP_SOURCE_DIR}/freexl" \
    --enable-shared \
    --disable-static
}

build_libspatialite() {
  local spatialite_args=(
    --enable-shared
    --disable-static
    --disable-examples
    --disable-freexl
    --disable-gcp
    --disable-geosadvanced
    --disable-libxml2
    --disable-minizip
    --disable-proj
    --disable-rttopo
    "--with-geosconfig=${SDK_PREFIX}/bin/geos-config"
  )

  LD_LIBRARY_PATH="${SDK_PREFIX}/lib64:${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    LIBXML2_CFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/libxml2" \
    LIBXML2_LIBS="-L${SDK_PREFIX}/lib -lxml2" \
    LIBS="-L${SDK_PREFIX}/lib -liconv ${LIBS:-}" \
    configure_make_install libspatialite "${DEP_SOURCE_DIR}/libspatialite" \
    "${spatialite_args[@]}"
}

build_gdal() {
  local gdal_args=(
    -DBUILD_SHARED_LIBS=ON
    -DBUILD_TESTING=OFF
    -DBUILD_APPS=OFF
    -DGDAL_BUILD_OPTIONAL_DRIVERS=ON
    -DOGR_BUILD_OPTIONAL_DRIVERS=ON
    -DGDAL_USE_INTERNAL_LIBS=OFF
    -DGDAL_USE_POSTGRESQL=OFF
    -DGDAL_USE_PG=OFF
    -DGDAL_USE_LIBPQ=OFF
    -DGDAL_USE_PYTHON=OFF
    -DBUILD_PYTHON_BINDINGS=OFF
    -DBUILD_PYTHON_STUBS=OFF
    -DBUILD_JAVA_BINDINGS=OFF
    -DBUILD_CSHARP_BINDINGS=OFF
    -DGDAL_USE_JPEG=ON
    -DGDAL_USE_PNG=ON
    -DGDAL_USE_TIFF=ON
    -DGDAL_USE_GEOTIFF=ON
    -DGDAL_USE_GEOTIFF_INTERNAL=OFF
    -DGDAL_USE_PROJ=ON
    -DGDAL_USE_GEOS=ON
    -DGDAL_USE_SQLITE3=ON
    -DGDAL_USE_SPATIALITE=ON
    -DGDAL_USE_CURL=ON
    -DGDAL_USE_LIBXML2=ON
    -DGDAL_USE_EXPAT=ON
    -DGDAL_USE_ZLIB=ON
    -DGDAL_USE_ZSTD=ON
    -DGDAL_USE_LIBLZMA=ON
    -DGDAL_USE_OPENSSL=ON
    -DGDAL_USE_YAML=ON
    -DGDAL_USE_MYSQL=OFF
    -DGDAL_USE_ODBC=OFF
    -DGDAL_USE_HDF5=OFF
    -DGDAL_USE_NETCDF=OFF
    -DGDAL_USE_PODOFO=OFF
    -DGDAL_USE_POPPLER=OFF
    -DGDAL_USE_QHULL=OFF
    -DGDAL_USE_WEBP=OFF
    -DGDAL_USE_JXL=OFF
    -DGDAL_USE_OPENJPEG=OFF
    -DGDAL_USE_ARROW=OFF
    -DGDAL_USE_PARQUET=OFF
    -DGDAL_USE_AVIF=OFF
    -DGDAL_USE_CRNLIB=OFF
    -DGDAL_USE_LERC=OFF
    -DGDAL_USE_BLURAY=OFF
    -DGDAL_USE_MONGOCXX=OFF
    -DGDAL_USE_HEIF=OFF
    -DCMAKE_DISABLE_FIND_PACKAGE_PostgreSQL=ON
    -DCMAKE_DISABLE_FIND_PACKAGE_Python=ON
    -DCMAKE_DISABLE_FIND_PACKAGE_Iconv=OFF
  )

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    gdal_args+=(
      -DGDAL_USE_FREEXL=OFF
      -DHAVE_5ARGS_MREMAP=OFF
      -DHAVE_CTIME_R=OFF
      -DHAVE_DL_ITERATE_PHDR=OFF
      -DHAVE_GETRLIMIT=OFF
      -DHAVE_GMTIME_R=OFF
      -DHAVE_LOCALTIME_R=OFF
      -DHAVE_MMAP=OFF
      -DHAVE_POSIX_SPAWNP=OFF
      -DHAVE_POSIX_MEMALIGN=OFF
      -DHAVE_PTHREAD_ATFORK=OFF
      -DHAVE_SIGACTION=OFF
      -DHAVE_STATVFS=OFF
      -DHAVE_STATVFS64=OFF
      -DHAVE_VFORK=OFF
      -DSQLite3_HAS_COLUMN_METADATA=OFF
    )
  else
    gdal_args+=(
      -DGDAL_USE_FREEXL=ON
    )
  fi

  cmake_install gdal "${DEP_SOURCE_DIR}/gdal" "${gdal_args[@]}"
}

validate_gdal() {
  [[ -f "${SDK_PREFIX}/include/geos_c.h" ]] || die "missing GEOS headers"
  [[ -f "${SDK_PREFIX}/include/proj.h" ]] || die "missing PROJ headers"
  [[ -f "${SDK_PREFIX}/include/geotiff.h" || -f "${SDK_PREFIX}/include/libgeotiff/geotiff.h" ]] || die "missing libgeotiff headers"
  [[ -f "${SDK_PREFIX}/include/spatialite.h" ]] || die "missing SpatiaLite headers"
  [[ -f "${SDK_PREFIX}/include/gdal.h" ]] || die "missing GDAL headers"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*gdal*.dll' -o -name '*gdal*.dll.a' \) | grep -q . || die "missing GDAL DLL/import library"
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*geos*.dll' -o -name '*geos*.dll.a' \) | grep -q . || die "missing GEOS DLL/import library"
    find "${SDK_PREFIX}" \( -type f -o -type l \) \( -name '*proj*.dll' -o -name '*proj*.dll.a' \) | grep -q . || die "missing PROJ DLL/import library"
    return 0
  fi

  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libgdal.so*' | grep -q . || die "missing libgdal shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libgeos_c.so*' | grep -q . || die "missing libgeos_c shared library"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libproj.so*' | grep -q . || die "missing libproj shared library"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/gdal-${GDAL_VERSION:-3.13.1}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

GEOS_VERSION="${GEOS_VERSION:-3.14.1}"
LIBYAML_VERSION="${LIBYAML_VERSION:-0.2.5}"
PROJ_VERSION="${PROJ_VERSION:-9.8.1}"
LIBGEOTIFF_VERSION="${LIBGEOTIFF_VERSION:-1.7.4}"
FREEXL_VERSION="${FREEXL_VERSION:-2.0.0}"
LIBSPATIALITE_VERSION="${LIBSPATIALITE_VERSION:-5.1.0}"
GDAL_VERSION="${GDAL_VERSION:-3.13.1}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing GDAL package prefix: ${SDK_PREFIX}"
[[ -f "${SDK_PREFIX}/README.postgresql-dependencies" ]] || die "missing base marker: ${SDK_PREFIX}/README.postgresql-dependencies"
[[ -f "${SDK_PREFIX}/README.image" ]] || die "missing image marker: ${SDK_PREFIX}/README.image"

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
  CONFIGURE_BUILD_TRIPLE="${ARCH}-gdalbuild-linux-gnu"
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

DEP_SOURCE_DIR="${BUILD_DIR}/src/gdal"
DEP_BUILD_DIR="${BUILD_DIR}/build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"
TOOLCHAIN_FILE="${BUILD_TOOLS}/cmake-toolchain.cmake"

mkdir -p "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS" "${SDK_PREFIX}/lib"

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

if [[ "$TARGET_KIND" == "mingw" ]]; then
  SQLITE3_LIBRARY="${SQLITE3_LIBRARY:-${SDK_PREFIX}/lib/libsqlite3.dll.a}"
  CURL_LIBRARY="${CURL_LIBRARY:-${SDK_PREFIX}/lib/libcurl.dll.a}"
  TIFF_LIBRARY="${TIFF_LIBRARY:-${SDK_PREFIX}/lib/libtiff.dll.a}"
  PROJ_LIBRARY="${PROJ_LIBRARY:-${SDK_PREFIX}/lib/libproj.dll.a}"
else
  SQLITE3_LIBRARY="${SQLITE3_LIBRARY:-${SDK_PREFIX}/lib/libsqlite3.so}"
  CURL_LIBRARY="${CURL_LIBRARY:-${SDK_PREFIX}/lib/libcurl.so}"
  TIFF_LIBRARY="${TIFF_LIBRARY:-${SDK_PREFIX}/lib/libtiff.so}"
  PROJ_LIBRARY="${PROJ_LIBRARY:-${SDK_PREFIX}/lib/libproj.so}"
fi

write_toolchain_file
rewrite_dependency_prefixes

GEOS_ARCHIVE="geos-${GEOS_VERSION}.tar.bz2"
LIBYAML_ARCHIVE="yaml-${LIBYAML_VERSION}.tar.gz"
PROJ_ARCHIVE="proj-${PROJ_VERSION}.tar.gz"
LIBGEOTIFF_ARCHIVE="libgeotiff-${LIBGEOTIFF_VERSION}.tar.gz"
FREEXL_ARCHIVE="freexl-${FREEXL_VERSION}.tar.gz"
LIBSPATIALITE_ARCHIVE="libspatialite-${LIBSPATIALITE_VERSION}.tar.gz"
GDAL_ARCHIVE="gdal-${GDAL_VERSION}.tar.gz"
ZLIB_ARCHIVE="zlib-1.3.2.tar.gz"

download_archive "https://download.osgeo.org/geos/${GEOS_ARCHIVE}" "$GEOS_ARCHIVE"
download_archive "https://pyyaml.org/download/libyaml/${LIBYAML_ARCHIVE}" "$LIBYAML_ARCHIVE"
download_archive "https://github.com/OSGeo/PROJ/releases/download/${PROJ_VERSION}/${PROJ_ARCHIVE}" "$PROJ_ARCHIVE"
download_archive "https://github.com/OSGeo/libgeotiff/releases/download/${LIBGEOTIFF_VERSION}/${LIBGEOTIFF_ARCHIVE}" "$LIBGEOTIFF_ARCHIVE"
download_archive "https://zlib.net/${ZLIB_ARCHIVE}" "$ZLIB_ARCHIVE"
download_archive "https://www.gaia-gis.it/gaia-sins/${FREEXL_ARCHIVE}" "$FREEXL_ARCHIVE"
download_archive "https://www.gaia-gis.it/gaia-sins/libspatialite-sources/${LIBSPATIALITE_ARCHIVE}" "$LIBSPATIALITE_ARCHIVE"
download_archive "https://github.com/OSGeo/gdal/releases/download/v${GDAL_VERSION}/${GDAL_ARCHIVE}" "$GDAL_ARCHIVE"

extract_archive_source "${DEP_SOURCE_DIR}/geos" "$GEOS_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/libyaml" "$LIBYAML_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/proj" "$PROJ_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/libgeotiff" "$LIBGEOTIFF_ARCHIVE" "CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/zlib" "$ZLIB_ARCHIVE" "contrib/minizip/CMakeLists.txt"
extract_archive_source "${DEP_SOURCE_DIR}/freexl" "$FREEXL_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/libspatialite" "$LIBSPATIALITE_ARCHIVE" "configure"
extract_archive_source "${DEP_SOURCE_DIR}/gdal" "$GDAL_ARCHIVE" "CMakeLists.txt"

apply_source_patch_once "${DEP_SOURCE_DIR}/libspatialite" "${PATCH_DIR}/libspatialite-5.1.0-generated-gaiaconfig.patch"
apply_source_patch_once "${DEP_SOURCE_DIR}/gdal" "${PATCH_DIR}/gdal-3.13.1-o-tmpfile-guard.patch"
apply_source_patch_once "${DEP_SOURCE_DIR}/gdal" "${PATCH_DIR}/gdal-3.13.1-mingw-getrlimit-guard.patch"

log "Installing GDAL dependencies into ${SDK_PREFIX}"
build_geos
build_libyaml
build_proj
build_libgeotiff
build_minizip
build_freexl
build_libspatialite
build_gdal
rewrite_dependency_prefixes
copy_cxx_runtime_libraries
copy_dependency_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
rewrite_linux_absolute_needed
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_gdal

render_template "${TEMPLATE_DIR}/README.gdal.in" "${SDK_PREFIX}/README.gdal" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "GEOS_VERSION=${GEOS_VERSION}" \
  "LIBYAML_VERSION=${LIBYAML_VERSION}" \
  "PROJ_VERSION=${PROJ_VERSION}" \
  "LIBGEOTIFF_VERSION=${LIBGEOTIFF_VERSION}" \
  "FREEXL_VERSION=${FREEXL_VERSION}" \
  "LIBSPATIALITE_VERSION=${LIBSPATIALITE_VERSION}" \
  "GDAL_VERSION=${GDAL_VERSION}"

log "GDAL package ready: ${SDK_PREFIX}"
