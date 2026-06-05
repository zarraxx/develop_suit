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

  if [[ ! -f "${extract_dir}/runtimes/CMakeLists.txt" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "${CACHE_DIR}/${LLVM_ARCHIVE_NAME}" -C "$extract_dir" --strip-components=1
  fi

  [[ -f "${extract_dir}/runtimes/CMakeLists.txt" ]] || die "invalid LLVM runtimes source tree: ${extract_dir}"
  printf '%s\n' "$extract_dir"
}

detect_cxx_abi_tls_dtor() {
  if [[ -n "${LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL:-}" ]]; then
    printf '%s\n' "$LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL"
    return 0
  fi

  printf '%s\n' OFF
}

write_runtime_wrapper() {
  local path="$1"
  local driver="$2"
  local is_cxx="$3"
  local add_runtime_link="$4"
  local add_cxx_headers="$5"
  local target_toolchain_args=""
  local linux_rpath_link_args=""
  local runtime_link_args=""
  local cxx_include_args=""

  append_wrapper_arg() {
    local -n buffer="$1"
    local arg="$2"

    buffer+="  ${arg} \\"$'\n'
  }

  if [[ "$TARGET_KIND" == "linux" ]]; then
    append_wrapper_arg linux_rpath_link_args "-Wl,-rpath-link,\"${RESOURCE_LIB_DIR}\""
    append_wrapper_arg linux_rpath_link_args "-Wl,-rpath-link,\"${RUNTIME_LIB_DIR}\""
    append_wrapper_arg linux_rpath_link_args "-Wl,-rpath-link,\"${SYSROOT}/usr/lib\""
    append_wrapper_arg linux_rpath_link_args "-Wl,-rpath-link,\"${SYSROOT}/usr/lib64\""
    append_wrapper_arg linux_rpath_link_args "-Wl,-rpath-link,\"${SYSROOT}/lib\""
    append_wrapper_arg linux_rpath_link_args "-Wl,-rpath-link,\"${SYSROOT}/lib64\""
  fi

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    append_wrapper_arg target_toolchain_args "-B\"${TARGET_ROOT}/bin\""
    append_wrapper_arg target_toolchain_args "-isystem \"${SYSROOT}/usr/${TARGET_TRIPLE}/include\""
    append_wrapper_arg target_toolchain_args "-L\"${SYSROOT}/usr/${TARGET_TRIPLE}/lib\""
    append_wrapper_arg target_toolchain_args "-L\"${SYSROOT}/lib\""
    append_wrapper_arg target_toolchain_args "-L\"${TARGET_ROOT}/lib\""
  fi

  if [[ "$add_runtime_link" == "1" ]]; then
    append_wrapper_arg runtime_link_args "--rtlib=compiler-rt"
    append_wrapper_arg runtime_link_args "--unwindlib=libunwind"
  fi

  if [[ "$add_cxx_headers" == "1" ]]; then
    append_wrapper_arg cxx_include_args "-stdlib=libc++"
    append_wrapper_arg cxx_include_args "-isystem \"${SDK_PREFIX}/include/c++/v1\""
    append_wrapper_arg cxx_include_args "-isystem \"${SDK_PREFIX}/include/${TARGET_TRIPLE}/c++/v1\""
  fi

  render_template "${TEMPLATE_DIR}/runtime-wrapper.in" "$path" \
    "DRIVER=${driver}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}" \
    "RESOURCE_DIR=${RESOURCE_DIR}" \
    "RESOURCE_LIB_DIR=${RESOURCE_LIB_DIR}" \
    "TARGET_BIN_DIR=${TARGET_BIN_DIR}" \
    "RUNTIME_LIB_DIR=${RUNTIME_LIB_DIR}" \
    "TARGET_TOOLCHAIN_ARGS=${target_toolchain_args}" \
    "LINUX_RPATH_LINK_ARGS=${linux_rpath_link_args}" \
    "RUNTIME_LINK_ARGS=${runtime_link_args}" \
    "CXX_INCLUDE_ARGS=${cxx_include_args}"

  chmod +x "$path"
}

configure_runtime_cmake() {
  local source_root="$1"
  local build_dir="$2"
  shift 2

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cmake -S "${source_root}/runtimes" -B "$build_dir" -G Ninja "$@"
}

build_runtime_install() {
  local build_dir="$1"

  cmake --build "$build_dir" --parallel "$JOBS" --target install
}

copy_resource_headers() {
  local source_resource_dir="${NATIVE_STAGE0_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}"

  [[ -d "${source_resource_dir}/include" ]] \
    || die "missing native stage0 resource headers: ${source_resource_dir}/include"

  mkdir -p "$RESOURCE_DIR"
  cp -a "${source_resource_dir}/include" "$RESOURCE_DIR/"
}

runtime_common_args() {
  local cc_wrapper="$1"
  local cxx_wrapper="$2"
  local install_prefix="$3"

  RUNTIME_COMMON_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME"
    -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR"
    -DCMAKE_INSTALL_PREFIX="$install_prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INSTALL_INCLUDEDIR=include
    -DCMAKE_C_COMPILER="$cc_wrapper"
    -DCMAKE_CXX_COMPILER="$cxx_wrapper"
    -DCMAKE_ASM_COMPILER="$cc_wrapper"
    -DCMAKE_AR="${PREBUILT_LLVM_ROOT}/bin/llvm-ar"
    -DCMAKE_NM="${PREBUILT_LLVM_ROOT}/bin/llvm-nm"
    -DCMAKE_OBJCOPY="${PREBUILT_LLVM_ROOT}/bin/llvm-objcopy"
    -DCMAKE_RANLIB="${PREBUILT_LLVM_ROOT}/bin/llvm-ranlib"
    -DCMAKE_STRIP="${PREBUILT_LLVM_ROOT}/bin/llvm-strip"
    -DCMAKE_LINKER="${NATIVE_STAGE0_PREFIX}/bin/ld.lld"
    -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}"
    -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}"
    -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}"
    -DCMAKE_SYSROOT="${SYSROOT}"
    "-DCMAKE_FIND_ROOT_PATH=${SDK_PREFIX};${TARGET_ROOT};${SYSROOT}"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -L${RESOURCE_LIB_DIR} -L${RUNTIME_LIB_DIR}"
    "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -L${RESOURCE_LIB_DIR} -L${RUNTIME_LIB_DIR}"
    "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld -L${RESOURCE_LIB_DIR} -L${RUNTIME_LIB_DIR}"
    "-DLLVM_PATH=${LLVM_SOURCE_ROOT}/llvm"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=${TARGET_TRIPLE}"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
    -DLIBUNWIND_INCLUDE_TESTS=OFF
    -DLIBCXXABI_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_TESTS=OFF
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF
    -DLIBCXX_CXX_ABI=libcxxabi
    "-DPython3_EXECUTABLE=${HOST_PYTHON3}"
    "-DPYTHON_EXECUTABLE=${HOST_PYTHON3}"
  )
}

build_compiler_rt_builtins() {
  local wrappers="${BUILD_DIR}/wrappers/compiler-rt-builtins"
  local build_dir="${BUILD_DIR}/runtimes/compiler-rt-builtins"

  mkdir -p "$wrappers" "$RESOURCE_LIB_DIR"
  write_runtime_wrapper "${wrappers}/clang" "${NATIVE_STAGE0_PREFIX}/bin/clang" 0 0 0
  write_runtime_wrapper "${wrappers}/clang++" "${NATIVE_STAGE0_PREFIX}/bin/clang++" 1 0 0
  runtime_common_args "${wrappers}/clang" "${wrappers}/clang++" "$SDK_PREFIX"

  log "Configuring compiler-rt builtins for ${TARGET_TRIPLE}"
  configure_runtime_cmake "$LLVM_SOURCE_ROOT" "$build_dir" \
    "${RUNTIME_COMMON_ARGS[@]}" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_CRT=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=OFF \
    "-DCOMPILER_RT_INSTALL_LIBRARY_DIR=${RESOURCE_DIR}/lib"

  log "Installing compiler-rt builtins for ${TARGET_TRIPLE}"
  build_runtime_install "$build_dir"
}

build_cxx_runtimes() {
  local wrappers="${BUILD_DIR}/wrappers/cxx-runtimes"
  local build_dir="${BUILD_DIR}/runtimes/cxx"
  local tls_dtor=""
  local cxx_runtime_extra=()

  mkdir -p "$wrappers" "$RESOURCE_LIB_DIR" "$RUNTIME_LIB_DIR"
  write_runtime_wrapper "${wrappers}/clang" "${NATIVE_STAGE0_PREFIX}/bin/clang" 0 1 0
  write_runtime_wrapper "${wrappers}/clang++" "${NATIVE_STAGE0_PREFIX}/bin/clang++" 1 1 0
  runtime_common_args "${wrappers}/clang" "${wrappers}/clang++" "$SDK_PREFIX"
  tls_dtor="$(detect_cxx_abi_tls_dtor)"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cxx_runtime_extra+=(
      -DLIBUNWIND_HAS_C_LIB=OFF
      -DLIBUNWIND_HAS_DL_LIB=OFF
      -DLIBUNWIND_HAS_PTHREAD_LIB=OFF
      -DLIBCXXABI_HAS_C_LIB=OFF
      -DLIBCXXABI_HAS_DL_LIB=OFF
      -DLIBCXXABI_HAS_PTHREAD_LIB=OFF
      -DLIBCXXABI_HAS_WIN32_THREAD_API=ON
      -DLIBCXXABI_ENABLE_SHARED=OFF
      -DLIBCXX_HAS_PTHREAD_LIB=OFF
      -DLIBCXX_HAS_RT_LIB=OFF
      -DLIBCXX_HAS_WIN32_THREAD_API=ON
      -DLIBCXX_EXTRA_SITE_DEFINES=__USE_MINGW_ANSI_STDIO=1
    )
  fi

  log "Configuring libunwind/libc++abi/libc++ for ${TARGET_TRIPLE}"
  configure_runtime_cmake "$LLVM_SOURCE_ROOT" "$build_dir" \
    "${RUNTIME_COMMON_ARGS[@]}" \
    "-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx" \
    -DLIBUNWIND_ENABLE_SHARED=ON \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBUNWIND_USE_COMPILER_RT=ON \
    -DLIBCXXABI_ENABLE_SHARED=ON \
    -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    "-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=${tls_dtor}" \
    -DLIBCXX_ENABLE_SHARED=ON \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
    -DLIBCXX_HAS_ATOMIC_LIB=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON \
    -DLIBCXX_USE_LLVM_UNWINDER=ON \
    "${cxx_runtime_extra[@]}"

  log "Installing libunwind/libc++abi/libc++ for ${TARGET_TRIPLE}"
  build_runtime_install "$build_dir"
}

build_compiler_rt_full() {
  local wrappers="${BUILD_DIR}/wrappers/compiler-rt-full"
  local build_dir="${BUILD_DIR}/runtimes/compiler-rt-full"

  mkdir -p "$wrappers" "$RESOURCE_LIB_DIR" "$RUNTIME_LIB_DIR"
  write_runtime_wrapper "${wrappers}/clang" "${NATIVE_STAGE0_PREFIX}/bin/clang" 0 1 1
  write_runtime_wrapper "${wrappers}/clang++" "${NATIVE_STAGE0_PREFIX}/bin/clang++" 1 1 1
  runtime_common_args "${wrappers}/clang" "${wrappers}/clang++" "$SDK_PREFIX"

  local compiler_rt_extra=()
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    compiler_rt_extra+=(
      -DCOMPILER_RT_HAS_Z_TEXT=OFF
      -DCOMPILER_RT_HAS_VERSION_SCRIPT=OFF
      -DCOMPILER_RT_HAS_LIBDL=OFF
      -DCOMPILER_RT_HAS_LIBRT=OFF
      -DCOMPILER_RT_HAS_LIBPTHREAD=OFF
      -DCOMPILER_RT_HAS_LIBC=OFF
      -DSANITIZER_CXX_ABI=libc++
      -DSANITIZER_USE_STATIC_CXX_ABI=ON
      -DSANITIZER_USE_STATIC_LLVM_UNWINDER=ON
    )
  else
    compiler_rt_extra+=(
      -DSANITIZER_CXX_ABI=libcxxabi
    )
  fi

  log "Configuring full compiler-rt for ${TARGET_TRIPLE}"
  configure_runtime_cmake "$LLVM_SOURCE_ROOT" "$build_dir" \
    "${RUNTIME_COMMON_ARGS[@]}" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_CRT=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=ON \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=ON \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=ON \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DCOMPILER_RT_USE_LIBCXX=OFF \
    "-DCOMPILER_RT_INSTALL_LIBRARY_DIR=${RESOURCE_DIR}/lib" \
    "${compiler_rt_extra[@]}"

  log "Installing full compiler-rt for ${TARGET_TRIPLE}"
  build_runtime_install "$build_dir"
}

copy_runtime_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \;
}

prune_libtool_metadata() {
  find "$SDK_PREFIX" -type f -name '*.la' -delete
}

validate_outputs() {
  [[ -d "${SDK_PREFIX}/include/c++/v1" ]] || die "missing libc++ headers"
  [[ -d "$RESOURCE_LIB_DIR" ]] || die "missing compiler-rt resource lib dir: ${RESOURCE_LIB_DIR}"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    compgen -G "${SDK_PREFIX}/bin/libc++*.dll" >/dev/null || die "missing MinGW libc++ DLL in bin"
  else
    [[ -e "${RUNTIME_LIB_DIR}/libc++.so" || -e "${RUNTIME_LIB_DIR}/libc++.so.1" ]] || die "missing libc++.so"
    [[ -e "${RUNTIME_LIB_DIR}/libunwind.so" || -e "${RUNTIME_LIB_DIR}/libunwind.so.1" ]] || die "missing libunwind.so"
  fi

  compgen -G "${RESOURCE_LIB_DIR}/libclang_rt.builtins*.a" >/dev/null \
    || die "missing compiler-rt builtins in ${RESOURCE_LIB_DIR}"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_MAJOR_VERSION="${LLVM_MAJOR_VERSION:-${LLVM_VERSION%%.*}}"
BOOTSTRAP_LLVM_VERSION="${BOOTSTRAP_LLVM_VERSION:-18.1.8}"
PREBUILT_LLVM_ROOT="${PREBUILT_LLVM_ROOT:-/opt/llvm-${BOOTSTRAP_LLVM_VERSION}}"
NATIVE_STAGE0_PREFIX="${NATIVE_STAGE0_PREFIX:-/work/native-stage0}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/libcxx-${LLVM_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
HOST_PYTHON3="${HOST_PYTHON3:-/usr/bin/python3}"
LLVM_ARCHIVE_NAME="${LLVM_ARCHIVE_NAME:-llvm-project-${LLVM_VERSION}.src.tar.xz}"
LLVM_ARCHIVE_URL="${LLVM_ARCHIVE_URL:-https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}}"
RESOURCE_DIR="${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}"
RESOURCE_LIB_DIR="${RESOURCE_DIR}/lib/${TARGET_TRIPLE}"
RUNTIME_LIB_DIR="${SDK_PREFIX}/lib/${TARGET_TRIPLE}"
TARGET_BIN_DIR="${PREBUILT_LLVM_ROOT}/bin"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$PREBUILT_LLVM_ROOT" ]] || die "missing prebuilt LLVM root: ${PREBUILT_LLVM_ROOT}"
[[ -x "${NATIVE_STAGE0_PREFIX}/bin/clang" ]] || die "missing native stage0 clang"
[[ -x "${NATIVE_STAGE0_PREFIX}/bin/clang++" ]] || die "missing native stage0 clang++"
[[ -x "${NATIVE_STAGE0_PREFIX}/bin/ld.lld" ]] || die "missing native stage0 ld.lld"

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
    ;;
  mingw)
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac

[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

mkdir -p "$SDK_PREFIX" "$RESOURCE_LIB_DIR" "$RUNTIME_LIB_DIR"
copy_resource_headers

download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
LLVM_SOURCE_ROOT="$(extract_llvm_source)"

export LD_LIBRARY_PATH="${NATIVE_STAGE0_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

log "libcxx package target: ${TARGET_TRIPLE}"
log "target kind: ${TARGET_KIND}"
log "sysroot: ${SYSROOT}"
log "native stage0: ${NATIVE_STAGE0_PREFIX}"
log "resource dir: ${RESOURCE_DIR}"

build_compiler_rt_builtins
build_cxx_runtimes
build_compiler_rt_full
copy_runtime_dlls_to_bin
prune_libtool_metadata

render_template "${TEMPLATE_DIR}/README.libcxx.in" "${SDK_PREFIX}/README.libcxx" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}"

validate_outputs

log "libcxx package ready: ${SDK_PREFIX}"
