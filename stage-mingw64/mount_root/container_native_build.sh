#!/usr/bin/env bash

set -euo pipefail

TARGET_TRIPLE="x86_64-w64-windows-gnu"
LLVM_VERSION="18.1.8"
LLVM_MAJOR_VERSION="18"
LLVM_NATIVE_DIR_NAME="llvm18.1.8"
LLVM_ARCHIVE_NAME="llvm-project-${LLVM_VERSION}.src.tar.xz"
LLVM_ARCHIVE_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}"
BINUTILS_VERSION="2.46.0"
BINUTILS_ARCHIVE_NAME="binutils-${BINUTILS_VERSION}.tar.xz"
BINUTILS_ARCHIVE_URL="https://ftp.gnu.org/gnu/binutils/${BINUTILS_ARCHIVE_NAME}"
ZLIB_VERSION="1.3.2"
ZLIB_ARCHIVE_NAME="zlib-${ZLIB_VERSION}.tar.gz"
ZLIB_ARCHIVE_URL="https://zlib.net/${ZLIB_ARCHIVE_NAME}"
ZSTD_VERSION="1.5.7"
ZSTD_ARCHIVE_NAME="zstd-${ZSTD_VERSION}.tar.gz"
ZSTD_ARCHIVE_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/${ZSTD_ARCHIVE_NAME}"
LIBXML2_VERSION="2.15.3"
LIBXML2_ARCHIVE_NAME="libxml2-v${LIBXML2_VERSION}.tar.bz2"
LIBXML2_ARCHIVE_URL="https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML2_VERSION}/${LIBXML2_ARCHIVE_NAME}"

JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build"
OUT_DIR="/work/out"

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/container_native_build.sh [options]

Options:
  --jobs=<n>          Parallel build jobs
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  Build dir (default: /work/build)
  --out-dir=<path>    Output root dir (default: /work/out)
  -h, --help          Show this help
EOF
}

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

restore_host_access() {
  chmod -R a+rwX "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" 2>/dev/null || true
}

download_archive() {
  local url="$1"
  local archive="$2"

  mkdir -p "$CACHE_DIR"
  if [[ ! -s "${CACHE_DIR}/${archive}" ]]; then
    rm -f "${CACHE_DIR}/${archive}" "${CACHE_DIR}/${archive}.tmp"
    log "Downloading ${archive}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive}.tmp" "$url"
    mv "${CACHE_DIR}/${archive}.tmp" "${CACHE_DIR}/${archive}"
  fi
}

extract_llvm_source() {
  local extract_dir="${BUILD_DIR}/llvm-project"

  if [[ ! -f "${extract_dir}/llvm/CMakeLists.txt" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "${CACHE_DIR}/${LLVM_ARCHIVE_NAME}" -C "$extract_dir" --strip-components=1
  fi

  [[ -f "${extract_dir}/llvm/CMakeLists.txt" ]] || die "invalid LLVM source tree: ${extract_dir}"
  printf '%s\n' "$extract_dir"
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

build_native_cmake_package() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${BUILD_DIR}/native-deps-build/${package_name}"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring native Windows dependency: ${package_name}"
  cmake -S "$source_dir" -B "$package_build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_C_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-gcc" \
    -DCMAKE_CXX_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-g++" \
    -DCMAKE_RC_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/llvm-rc" \
    -DCMAKE_AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
    -DCMAKE_NM="/opt/llvm-${LLVM_VERSION}/bin/llvm-nm" \
    -DCMAKE_OBJCOPY="/opt/llvm-${LLVM_VERSION}/bin/llvm-objcopy" \
    -DCMAKE_RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
    -DCMAKE_STRIP="/opt/llvm-${LLVM_VERSION}/bin/llvm-strip" \
    -DCMAKE_SYSROOT="/opt/${TARGET_TRIPLE}/sysroot" \
    "-DCMAKE_FIND_ROOT_PATH=${DEPS_PREFIX};/opt/${TARGET_TRIPLE}/sysroot;/opt/${TARGET_TRIPLE}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    "$@"

  log "Building native Windows dependency: ${package_name}"
  cmake --build "$package_build_dir" --parallel "$JOBS"
  cmake --install "$package_build_dir"
}

build_native_dependencies() {
  local zlib_source="${BUILD_DIR}/native-deps-source/zlib"
  local zstd_source="${BUILD_DIR}/native-deps-source/zstd"
  local libxml2_source="${BUILD_DIR}/native-deps-source/libxml2"

  rm -rf "$DEPS_PREFIX"
  mkdir -p "$DEPS_PREFIX"

  extract_archive_source "$zlib_source" "$ZLIB_ARCHIVE_NAME" "CMakeLists.txt"
  extract_archive_source "$zstd_source" "$ZSTD_ARCHIVE_NAME" "build/cmake/CMakeLists.txt"
  extract_archive_source "$libxml2_source" "$LIBXML2_ARCHIVE_NAME" "CMakeLists.txt"

  build_native_cmake_package zlib "$zlib_source" \
    -DZLIB_BUILD_TESTING=OFF \
    -DZLIB_BUILD_SHARED=ON \
    -DZLIB_BUILD_STATIC=ON \
    -DZLIB_INSTALL=ON

  build_native_cmake_package zstd "${zstd_source}/build/cmake" \
    -DZSTD_BUILD_SHARED=ON \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_BUILD_CONTRIB=OFF \
    -DZSTD_MULTITHREAD_SUPPORT=OFF \
    -DZSTD_LEGACY_SUPPORT=OFF

  build_native_cmake_package libxml2 "$libxml2_source" \
    "-DCMAKE_PREFIX_PATH=${DEPS_PREFIX}" \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBXML2_WITH_ICONV=OFF \
    -DLIBXML2_WITH_ICU=OFF \
    -DLIBXML2_WITH_MODULES=OFF \
    -DLIBXML2_WITH_PYTHON=OFF \
    -DLIBXML2_WITH_TESTS=OFF \
    -DLIBXML2_WITH_PROGRAMS=OFF \
    -DLIBXML2_WITH_ZLIB=ON
}

copy_tree_contents() {
  local source_dir="$1"
  local dest_dir="$2"

  [[ -d "$source_dir" ]] || die "missing directory: ${source_dir}"
  mkdir -p "$dest_dir"
  cp -a "${source_dir}/." "$dest_dir/"
}

copy_runtime_dlls_to_bin() {
  local source_dir="$1"
  local dest_bin="$2"

  mkdir -p "$dest_bin"
  find "$source_dir" -type f -name '*.dll' -exec cp -f {} "$dest_bin/" \;
}

copy_installed_dlls_to_bin() {
  local final_root="$1"
  local dest_bin="${final_root}/bin"

  mkdir -p "$dest_bin"
  find "$final_root" \
    -path "${dest_bin}" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "$dest_bin/" \;
}

copy_dependency_dlls_to_bin() {
  local deps_prefix="$1"
  local final_root="$2"
  local dest_bin="${final_root}/bin"

  mkdir -p "$dest_bin"
  find "$deps_prefix" -type f -name '*.dll' -exec cp -f {} "$dest_bin/" \;
}

ensure_final_sysroot_aliases() {
  local sysroot="$1"
  local target_root="usr/${TARGET_TRIPLE}"
  local mingw_alias="x86_64-w64-mingw32"

  [[ -d "${sysroot}/${target_root}/include" ]] || die "missing final sysroot include dir"
  [[ -d "${sysroot}/${target_root}/lib" ]] || die "missing final sysroot lib dir"

  mkdir -p "${sysroot}/${TARGET_TRIPLE}" "${sysroot}/${mingw_alias}"
  ln -sfn "../${target_root}/include" "${sysroot}/${TARGET_TRIPLE}/include"
  ln -sfn "../${target_root}/lib" "${sysroot}/${TARGET_TRIPLE}/lib"
  ln -sfn "../${target_root}/include" "${sysroot}/${mingw_alias}/include"
  ln -sfn "../${target_root}/lib" "${sysroot}/${mingw_alias}/lib"
  ln -sfn "${target_root}" "${sysroot}/mingw"
}

write_clang_cfg() {
  local cfg_path="$1"
  local add_cxx="$2"

  cat >"$cfg_path" <<EOF
# Default relocatable Windows GNU configuration for ${TARGET_TRIPLE}.
--target=${TARGET_TRIPLE}
-resource-dir=<CFGDIR>/../lib/clang/${LLVM_MAJOR_VERSION}
-B
<CFGDIR>
EOF

  if [[ "$add_cxx" == 1 ]]; then
    cat >>"$cfg_path" <<EOF
-stdlib=libc++
-isystem
<CFGDIR>/../include/c++/v1
EOF
  fi

  cat >>"$cfg_path" <<EOF
-isystem
<CFGDIR>/../sysroot/usr/${TARGET_TRIPLE}/include
-L
<CFGDIR>/../sysroot/usr/${TARGET_TRIPLE}/lib
-L
<CFGDIR>/../lib/clang/${LLVM_MAJOR_VERSION}/lib/${TARGET_TRIPLE}
-L
<CFGDIR>/../lib/${TARGET_TRIPLE}
--rtlib=compiler-rt
--unwindlib=libunwind
EOF
}

write_cmake_toolchain() {
  local toolchain_path="$1"

  cat >"$toolchain_path" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

get_filename_component(_toolchain_dir "\${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)

set(CMAKE_C_COMPILER "\${_toolchain_dir}/bin/${TARGET_TRIPLE}-clang-gcc.exe")
set(CMAKE_CXX_COMPILER "\${_toolchain_dir}/bin/${TARGET_TRIPLE}-clang-g++.exe")
set(CMAKE_RC_COMPILER "\${_toolchain_dir}/bin/llvm-rc.exe")

set(CMAKE_SYSROOT "\${_toolchain_dir}/sysroot")
set(CMAKE_FIND_ROOT_PATH "\${_toolchain_dir}/sysroot" "\${_toolchain_dir}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

prepare_native_layout() {
  local final_root="$1"
  local source_target_root="/opt/${TARGET_TRIPLE}"
  local source_llvm_root="/opt/llvm-${LLVM_VERSION}"

  [[ -d "${source_target_root}/sysroot" ]] || die "missing stage-mingw64 sysroot: ${source_target_root}/sysroot"
  [[ -d "${source_target_root}/include/c++/v1" ]] || die "missing stage-mingw64 libc++ headers"
  [[ -d "${source_target_root}/lib/${TARGET_TRIPLE}" ]] || die "missing stage-mingw64 libc++ libraries"
  [[ -d "${source_llvm_root}/lib/clang/${LLVM_MAJOR_VERSION}" ]] || die "missing clang resource dir"

  rm -rf "$final_root"
  mkdir -p \
    "${final_root}/bin" \
    "${final_root}/include" \
    "${final_root}/lib" \
    "${final_root}/lib/clang/${LLVM_MAJOR_VERSION}/lib"

  copy_tree_contents "${source_target_root}/sysroot" "${final_root}/sysroot"
  copy_tree_contents "${source_target_root}/include" "${final_root}/include"
  copy_tree_contents "${source_target_root}/lib/${TARGET_TRIPLE}" "${final_root}/lib/${TARGET_TRIPLE}"
  copy_tree_contents "${source_llvm_root}/lib/clang/${LLVM_MAJOR_VERSION}" "${final_root}/lib/clang/${LLVM_MAJOR_VERSION}"
  ensure_final_sysroot_aliases "${final_root}/sysroot"

  copy_runtime_dlls_to_bin "${source_target_root}/bin" "${final_root}/bin"
  copy_runtime_dlls_to_bin "${source_target_root}/sysroot" "${final_root}/bin"
}

copy_clang_driver_aliases() {
  local bin_dir="$1"

  [[ -f "${bin_dir}/clang.exe" ]] || return 0
  cp -f "${bin_dir}/clang.exe" "${bin_dir}/${TARGET_TRIPLE}-clang-gcc.exe"
  cp -f "${bin_dir}/clang.exe" "${bin_dir}/${TARGET_TRIPLE}-clang.exe"

  if [[ -f "${bin_dir}/clang++.exe" ]]; then
    cp -f "${bin_dir}/clang++.exe" "${bin_dir}/${TARGET_TRIPLE}-clang-g++.exe"
  else
    cp -f "${bin_dir}/clang.exe" "${bin_dir}/clang++.exe"
    cp -f "${bin_dir}/clang.exe" "${bin_dir}/${TARGET_TRIPLE}-clang-g++.exe"
  fi
}

install_libcxx_config_site() {
  local final_root="$1"
  local config_site="${final_root}/include/${TARGET_TRIPLE}/c++/v1/__config_site"
  local generic_include="${final_root}/include/c++/v1"

  [[ -f "$config_site" ]] || die "missing libc++ __config_site: ${config_site}"
  [[ -d "$generic_include" ]] || die "missing libc++ include dir: ${generic_include}"
  cp -f "$config_site" "${generic_include}/__config_site"
}

assert_no_mingw_c_headers_in_libcxx_include() {
  local final_root="$1"
  local generic_include="${final_root}/include/c++/v1"
  local header
  local forbidden_headers=(
    _mingw.h
    corecrt.h
    corecrt_stdio_config.h
    crtdefs.h
    windows.h
    winnt.h
    winsock2.h
  )

  [[ -d "$generic_include" ]] || die "missing libc++ include dir: ${generic_include}"
  for header in "${forbidden_headers[@]}"; do
    [[ ! -e "${generic_include}/${header}" ]] || die "MinGW C header must not be installed into libc++ include dir: ${generic_include}/${header}"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --cache-dir=*)
      CACHE_DIR="${1#*=}"
      ;;
    --cache-dir)
      shift
      [[ $# -gt 0 ]] || die "--cache-dir requires a value"
      CACHE_DIR="$1"
      ;;
    --build-dir=*)
      BUILD_DIR="${1#*=}"
      ;;
    --build-dir)
      shift
      [[ $# -gt 0 ]] || die "--build-dir requires a value"
      BUILD_DIR="$1"
      ;;
    --out-dir=*)
      OUT_DIR="${1#*=}"
      ;;
    --out-dir)
      shift
      [[ $# -gt 0 ]] || die "--out-dir requires a value"
      OUT_DIR="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

require_command bash
require_command cmake
require_command ninja
require_command curl
require_command tar
require_command make

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"
trap restore_host_access EXIT INT TERM

FINAL_ROOT="${OUT_DIR}/${LLVM_NATIVE_DIR_NAME}"
DEPS_PREFIX="${BUILD_DIR}/native-deps-prefix"
LLVM_SOURCE_ROOT=""
LLVM_BUILD_DIR="${BUILD_DIR}/llvm-native-windows"

log "stage-mingw64 native Windows build"
log "target triple: ${TARGET_TRIPLE}"
log "out dir: ${FINAL_ROOT}"

download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
download_archive "$BINUTILS_ARCHIVE_URL" "$BINUTILS_ARCHIVE_NAME"
download_archive "$ZLIB_ARCHIVE_URL" "$ZLIB_ARCHIVE_NAME"
download_archive "$ZSTD_ARCHIVE_URL" "$ZSTD_ARCHIVE_NAME"
download_archive "$LIBXML2_ARCHIVE_URL" "$LIBXML2_ARCHIVE_NAME"

prepare_native_layout "$FINAL_ROOT"
build_native_dependencies

bash /work/mount_root/container_native_binutils.sh \
  --jobs="$JOBS" \
  --cache-dir="$CACHE_DIR" \
  --build-dir="$BUILD_DIR" \
  --prefix="$FINAL_ROOT"

LLVM_SOURCE_ROOT="$(extract_llvm_source)"
rm -rf "$LLVM_BUILD_DIR"
mkdir -p "$LLVM_BUILD_DIR"

log "Configuring native Windows LLVM/Clang"
cmake -S "${LLVM_SOURCE_ROOT}/llvm" -B "$LLVM_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_INSTALL_PREFIX="$FINAL_ROOT" \
  -DCMAKE_C_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-gcc" \
  -DCMAKE_CXX_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-g++" \
  -DCMAKE_ASM_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-gcc" \
  -DCMAKE_RC_COMPILER="/opt/llvm-${LLVM_VERSION}/bin/llvm-rc" \
  -DCMAKE_AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
  -DCMAKE_NM="/opt/llvm-${LLVM_VERSION}/bin/llvm-nm" \
  -DCMAKE_OBJCOPY="/opt/llvm-${LLVM_VERSION}/bin/llvm-objcopy" \
  -DCMAKE_RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
  -DCMAKE_STRIP="/opt/llvm-${LLVM_VERSION}/bin/llvm-strip" \
  -DCMAKE_LINKER="/opt/llvm-${LLVM_VERSION}/bin/ld.lld" \
  -DCMAKE_DLLTOOL="/opt/llvm-${LLVM_VERSION}/bin/llvm-dlltool" \
  -DCMAKE_SYSROOT="/opt/${TARGET_TRIPLE}/sysroot" \
  "-DCMAKE_FIND_ROOT_PATH=${DEPS_PREFIX};/opt/${TARGET_TRIPLE}/sysroot;/opt/${TARGET_TRIPLE};/opt/llvm-${LLVM_VERSION}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  "-DCMAKE_PREFIX_PATH=${DEPS_PREFIX}" \
  -DLLVM_ENABLE_PROJECTS=clang\;clang-tools-extra\;lld \
  -DLLVM_TARGETS_TO_BUILD=X86\;AArch64\;RISCV \
  -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=WebAssembly\;LoongArch \
  -DLLVM_HOST_TRIPLE="${TARGET_TRIPLE}" \
  -DLLVM_TARGET_ARCH=X86 \
  -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
  -DDEFAULT_SYSROOT="../sysroot" \
  "-DLLVM_NATIVE_TOOL_DIR=/opt/llvm-${LLVM_VERSION}/bin" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INSTALL_UTILS=ON \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBXML2=ON \
  -DLLVM_ENABLE_ZLIB=ON \
  -DLLVM_ENABLE_ZSTD=ON \
  -DHAVE__ALLOCA=OFF \
  -DHAVE___ALLOCA=OFF \
  -DHAVE___CHKSTK=OFF \
  -DHAVE___CHKSTK_MS=OFF \
  -DHAVE____CHKSTK=OFF \
  -DHAVE____CHKSTK_MS=OFF \
  "-DZLIB_ROOT=${DEPS_PREFIX}" \
  "-Dzstd_DIR=${DEPS_PREFIX}/lib/cmake/zstd" \
  "-DLibXml2_DIR=${DEPS_PREFIX}/lib/cmake/libxml2" \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DCLANG_LINK_CLANG_DYLIB=ON \
  -DCLANG_DEFAULT_LINKER=lld \
  -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
  -DCLANG_DEFAULT_RTLIB=compiler-rt \
  -DCLANG_DEFAULT_UNWINDLIB=libunwind \
  "-DPython3_EXECUTABLE=/usr/bin/python3"

log "Building native Windows LLVM/Clang"
cmake --build "$LLVM_BUILD_DIR" --parallel "$JOBS"

log "Installing native Windows LLVM/Clang"
cmake --install "$LLVM_BUILD_DIR"

copy_dependency_dlls_to_bin "$DEPS_PREFIX" "$FINAL_ROOT"
copy_installed_dlls_to_bin "$FINAL_ROOT"
copy_clang_driver_aliases "${FINAL_ROOT}/bin"
install_libcxx_config_site "$FINAL_ROOT"
assert_no_mingw_c_headers_in_libcxx_include "$FINAL_ROOT"
write_clang_cfg "${FINAL_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc.cfg" 0
write_clang_cfg "${FINAL_ROOT}/bin/${TARGET_TRIPLE}-clang-g++.cfg" 1
write_cmake_toolchain "${FINAL_ROOT}/toolchain.cmake"

cat >"${FINAL_ROOT}/README.stage-mingw64-native" <<EOF
This directory is a copy-and-run Windows-native LLVM/MinGW toolchain.

Target triple: ${TARGET_TRIPLE}
LLVM version: ${LLVM_VERSION}

Layout:
  bin/       Windows .exe tools and required .dll runtime libraries
  sysroot/   MinGW64 sysroot embedded as clang's default ../sysroot
  lib/       clang resource files and static target runtimes
  include/   libc++/libunwind headers

The clang default sysroot is built as a relative ../sysroot path, so the whole
llvm18.1.8 directory can be copied to another machine.
EOF

log "stage-mingw64 native Windows build ok: ${FINAL_ROOT}"
