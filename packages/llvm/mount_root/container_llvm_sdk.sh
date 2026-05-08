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

extract_llvm_source() {
  local extract_dir="${BUILD_DIR}/llvm-project-${LLVM_VERSION}.src"

  if [[ ! -f "${extract_dir}/llvm/CMakeLists.txt" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "${CACHE_DIR}/${LLVM_ARCHIVE_NAME}" -C "$extract_dir" --strip-components=1
  fi

  [[ -f "${extract_dir}/llvm/CMakeLists.txt" ]] || die "invalid LLVM source tree: ${extract_dir}"
  printf '%s\n' "$extract_dir"
}

copy_runtime_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \;
}

copy_linux_cxx_runtime_libraries() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  local runtime_lib_dir=""
  local candidate
  for candidate in \
    "${LLVM_ROOT}/lib/${TARGET_TRIPLE}" \
    "${LLVM_ROOT}/lib/clang/${LLVM_MAJOR_VERSION}/lib/${TARGET_TRIPLE}"
  do
    if [[ -f "${candidate}/libc++.so.1" && -f "${candidate}/libc++abi.so.1" && -f "${candidate}/libunwind.so.1" ]]; then
      runtime_lib_dir="$candidate"
      break
    fi
  done

  [[ -n "$runtime_lib_dir" ]] || die "missing LLVM C++ runtime libraries for ${TARGET_TRIPLE}"

  log "Copying LLVM C++ runtime libraries from ${runtime_lib_dir}"
  mkdir -p "${SDK_PREFIX}/lib"
  cp -a "${runtime_lib_dir}"/libc++.so* "${SDK_PREFIX}/lib/"
  cp -a "${runtime_lib_dir}"/libc++abi.so* "${SDK_PREFIX}/lib/"
  cp -a "${runtime_lib_dir}"/libunwind.so* "${SDK_PREFIX}/lib/"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_MAJOR_VERSION="${LLVM_MAJOR_VERSION:-${LLVM_VERSION%%.*}}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
LLVM_ARCHIVE_NAME="${LLVM_ARCHIVE_NAME:-llvm-project-${LLVM_VERSION}.src.tar.xz}"
LLVM_ARCHIVE_URL="${LLVM_ARCHIVE_URL:-https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}}"
LLVM_TARGETS="${LLVM_TARGETS:-all}"
LLVM_EXPERIMENTAL_TARGETS="${LLVM_EXPERIMENTAL_TARGETS:-all}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"

require_command curl
require_command tar
require_command cmake
require_command ninja

case "$TARGET_KIND" in
  linux)
    CMAKE_SYSTEM_NAME="Linux"
    CMAKE_SYSTEM_PROCESSOR="$ARCH"
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    LLVM_ENABLE_TERMINFO="${LLVM_ENABLE_TERMINFO:-ON}"
    LLVM_ENABLE_LIBEDIT="${LLVM_ENABLE_LIBEDIT:-OFF}"
    INSTALL_RPATH_ARG="-DCMAKE_INSTALL_RPATH=\$ORIGIN/../lib"
    ;;
  mingw)
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    LLVM_ENABLE_TERMINFO="${LLVM_ENABLE_TERMINFO:-OFF}"
    LLVM_ENABLE_LIBEDIT="${LLVM_ENABLE_LIBEDIT:-OFF}"
    INSTALL_RPATH_ARG="-DCMAKE_INSTALL_RPATH="
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac

[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"
[[ -f "${SDK_PREFIX}/include/zlib.h" ]] || die "missing zlib in SDK prefix: ${SDK_PREFIX}"
[[ -d "${SDK_PREFIX}/include/libxml2" ]] || die "missing libxml2 in SDK prefix: ${SDK_PREFIX}"
[[ -d "${SDK_PREFIX}/include" ]] || die "missing SDK include dir: ${SDK_PREFIX}/include"
[[ -d "${SDK_PREFIX}/lib" ]] || die "missing SDK lib dir: ${SDK_PREFIX}/lib"

CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy}"

if [[ ! -x "$CC" ]]; then
  CC="${LLVM_ROOT}/bin/clang"
  C_COMPILER_TARGET_ARG="-DCMAKE_C_COMPILER_TARGET=${TARGET_TRIPLE}"
else
  C_COMPILER_TARGET_ARG="-DCMAKE_C_COMPILER_TARGET=${TARGET_TRIPLE}"
fi
if [[ ! -x "$CXX" ]]; then
  CXX="${LLVM_ROOT}/bin/clang++"
  CXX_COMPILER_TARGET_ARG="-DCMAKE_CXX_COMPILER_TARGET=${TARGET_TRIPLE}"
else
  CXX_COMPILER_TARGET_ARG="-DCMAKE_CXX_COMPILER_TARGET=${TARGET_TRIPLE}"
fi
[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$OBJCOPY" ]] || OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy"

LLVM_BUILD_DIR="${BUILD_DIR}/llvm-sdk-build"
LINK_FLAGS="-L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  LINK_FLAGS="${LINK_FLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi

download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
LLVM_SOURCE_ROOT="$(extract_llvm_source)"

rm -rf "$LLVM_BUILD_DIR"
mkdir -p "$LLVM_BUILD_DIR"

log "Configuring LLVM SDK"
log "Target triple: ${TARGET_TRIPLE}"
log "LLVM targets: ${LLVM_TARGETS}"
log "LLVM experimental targets: ${LLVM_EXPERIMENTAL_TARGETS}"

cmake -S "${LLVM_SOURCE_ROOT}/llvm" -B "$LLVM_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
  -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
  -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  "$C_COMPILER_TARGET_ARG" \
  "$CXX_COMPILER_TARGET_ARG" \
  -DCMAKE_ASM_COMPILER="$CC" \
  -DCMAKE_ASM_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_AR="$AR" \
  -DCMAKE_RANLIB="$RANLIB" \
  -DCMAKE_STRIP="$STRIP" \
  -DCMAKE_NM="$NM" \
  -DCMAKE_OBJCOPY="$OBJCOPY" \
  -DCMAKE_SYSROOT="$SYSROOT" \
  "-DCMAKE_FIND_ROOT_PATH=${SDK_PREFIX};${SYSROOT};${TARGET_ROOT};${LLVM_ROOT}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
  "-DCMAKE_EXE_LINKER_FLAGS=${LINK_FLAGS}" \
  "-DCMAKE_SHARED_LINKER_FLAGS=${LINK_FLAGS}" \
  "$INSTALL_RPATH_ARG" \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  "-DLLVM_NATIVE_TOOL_DIR=${LLVM_ROOT}/bin" \
  "-DLLVM_TABLEGEN=${LLVM_ROOT}/bin/llvm-tblgen" \
  "-DLLVM_NM=${LLVM_ROOT}/bin/llvm-nm" \
  "-DLLVM_READOBJ=${LLVM_ROOT}/bin/llvm-readobj" \
  "-DLLVM_CONFIG_PATH=${LLVM_ROOT}/bin/llvm-config" \
  "-DLLVM_TARGETS_TO_BUILD=${LLVM_TARGETS}" \
  "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=${LLVM_EXPERIMENTAL_TARGETS}" \
  "-DLLVM_HOST_TRIPLE=${TARGET_TRIPLE}" \
  "-DLLVM_DEFAULT_TARGET_TRIPLE=${TARGET_TRIPLE}" \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_BENCHMARKS=OFF \
  -DLLVM_INSTALL_UTILS=ON \
  -DLLVM_BUILD_TOOLS=ON \
  -DLLVM_BUILD_UTILS=ON \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_THREADS=ON \
  -DLLVM_ENABLE_ZLIB=FORCE_ON \
  -DLLVM_ENABLE_ZSTD=FORCE_ON \
  -DLLVM_ENABLE_LIBXML2=FORCE_ON \
  "-DLLVM_ENABLE_TERMINFO=${LLVM_ENABLE_TERMINFO}" \
  "-DLLVM_ENABLE_LIBEDIT=${LLVM_ENABLE_LIBEDIT}" \
  -DLLVM_ENABLE_FFI=ON \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLVM_DYLIB_COMPONENTS=all \
  "-DZLIB_ROOT=${SDK_PREFIX}" \
  "-Dzstd_DIR=${SDK_PREFIX}/lib/cmake/zstd" \
  "-DLibXml2_DIR=${SDK_PREFIX}/lib/cmake/libxml2" \
  "-DIconv_INCLUDE_DIR=${SDK_PREFIX}/include" \
  "-DIconv_LIBRARY=${SDK_PREFIX}/lib/libiconv.a" \
  "-DFFI_INCLUDE_DIR=${SDK_PREFIX}/include" \
  "-DFFI_LIBRARY_DIR=${SDK_PREFIX}/lib" \
  "-DFFI_LIBRARY=${SDK_PREFIX}/lib/libffi.a" \
  "-DCURSES_INCLUDE_PATH=${SDK_PREFIX}/include/ncursesw" \
  "-DCURSES_LIBRARY=${SDK_PREFIX}/lib/libncursesw.so" \
  "-DCURSES_TINFO_LIBRARY=${SDK_PREFIX}/lib/libtinfow.so"

log "Building LLVM SDK"
cmake --build "$LLVM_BUILD_DIR" --parallel "$JOBS"

log "Installing LLVM SDK"
cmake --install "$LLVM_BUILD_DIR"
copy_linux_cxx_runtime_libraries
copy_runtime_dlls_to_bin

render_template "${TEMPLATE_DIR}/README.llvmsdk.in" "${SDK_PREFIX}/README.llvmsdk" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "LLVM_TARGETS=${LLVM_TARGETS}" \
  "LLVM_EXPERIMENTAL_TARGETS=${LLVM_EXPERIMENTAL_TARGETS}"

log "LLVM SDK ready: ${SDK_PREFIX}"
