#!/usr/bin/env bash

set -euo pipefail

TARGET_TRIPLE="x86_64-w64-windows-gnu"
LLVM_VERSION="18.1.8"
LLVM_RESOURCE_VERSION="18"
BINUTILS_VERSION="2.46.0"
MINGW_ARCHIVE_NAME="compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz"
MINGW_ARCHIVE_URL="https://github.com/zarraxx/package_builder/releases/download/compiler-mingw32-gcc-15.2.0/compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz"
LLVM_ARCHIVE_NAME="llvm-project-${LLVM_VERSION}.src.tar.xz"
LLVM_ARCHIVE_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}"
BINUTILS_ARCHIVE_NAME="binutils-${BINUTILS_VERSION}.tar.xz"
BINUTILS_ARCHIVE_URL="https://ftp.gnu.org/gnu/binutils/${BINUTILS_ARCHIVE_NAME}"

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/container_build.sh --arch=<arch> [options]

Options:
  --arch=<arch>       Host arch for produced Linux tools:
                      x86_64, aarch64, riscv64, loongarch64
  --jobs=<n>          Parallel build jobs
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  Build dir (default: /work/build)
  --out-dir=<path>    DESTDIR output dir (default: /work/out/<arch>)
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

normalize_arch() {
  case "$1" in
    x86_64|amd64|x64|x86)
      echo "x86_64"
      ;;
    aarch64|arm64)
      echo "aarch64"
      ;;
    riscv64|riscv64gc)
      echo "riscv64"
      ;;
    loongarch64|loong64)
      echo "loongarch64"
      ;;
    *)
      die "unsupported arch: $1"
      ;;
  esac
}

find_mingw_root() {
  local extract_dir="$1"
  local found_gcc=""

  found_gcc="$(find "$extract_dir" -type f -path "*/bin/*-gcc" -perm -111 | head -n 1 || true)"
  if [[ -n "$found_gcc" ]]; then
    dirname "$(dirname "$found_gcc")"
    return 0
  fi

  return 1
}

detect_package_triple() {
  local install_root="$1"
  local found_gcc=""
  local tool_name=""

  found_gcc="$(find "$install_root/bin" -maxdepth 1 -type f -name '*-gcc' -perm -111 | head -n 1 || true)"
  [[ -n "$found_gcc" ]] || return 1

  tool_name="$(basename "$found_gcc")"
  printf '%s\n' "${tool_name%-gcc}"
}

rename_dir_if_exists() {
  local old_path="$1"
  local new_path="$2"

  if [[ -d "$old_path" && "$old_path" != "$new_path" ]]; then
    [[ ! -e "$new_path" ]] || die "cannot rename ${old_path}; destination exists: ${new_path}"
    mv "$old_path" "$new_path"
  fi
}

rename_prefixed_tools() {
  local bin_dir="$1"
  local old_triple="$2"
  local new_triple="$3"
  local tool=""
  local tool_base=""
  local new_tool=""

  [[ "$old_triple" != "$new_triple" ]] || return 0

  for tool in "${bin_dir}/${old_triple}"-*; do
    [[ -e "$tool" ]] || continue
    tool_base="$(basename "$tool")"
    new_tool="${bin_dir}/${new_triple}${tool_base#${old_triple}}"
    [[ ! -e "$new_tool" ]] || die "cannot rename ${tool}; destination exists: ${new_tool}"
    mv "$tool" "$new_tool"
  done
}

normalize_seed_triple() {
  local seed_root="$1"
  local package_triple="$2"

  rename_prefixed_tools "${seed_root}/bin" "$package_triple" "$TARGET_TRIPLE"
  rename_dir_if_exists "${seed_root}/${package_triple}" "${seed_root}/${TARGET_TRIPLE}"
  rename_dir_if_exists "${seed_root}/lib/gcc/${package_triple}" "${seed_root}/lib/gcc/${TARGET_TRIPLE}"
  rename_dir_if_exists "${seed_root}/libexec/gcc/${package_triple}" "${seed_root}/libexec/gcc/${TARGET_TRIPLE}"
  rename_dir_if_exists \
    "${seed_root}/${TARGET_TRIPLE}/sysroot/usr/${package_triple}" \
    "${seed_root}/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}"
  rename_dir_if_exists \
    "${seed_root}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION:-15.2.0}/${package_triple}" \
    "${seed_root}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION:-15.2.0}/${TARGET_TRIPLE}"
}

extract_llvm_source() {
  local extract_dir="${BUILD_DIR}/${ARCH}/llvm-project"

  if [[ ! -f "${extract_dir}/llvm/CMakeLists.txt" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "${CACHE_DIR}/${LLVM_ARCHIVE_NAME}" -C "$extract_dir" --strip-components=1
  fi

  [[ -f "${extract_dir}/runtimes/CMakeLists.txt" ]] || die "invalid LLVM source tree: ${extract_dir}"
  printf '%s\n' "$extract_dir"
}

remove_seed_runtime_artifacts() {
  local final_root="$1"

  find "${final_root}/sysroot" -type f \( \
      -name 'libgcc*' \
      -o -name 'libstdc++*' \
      -o -name 'libgomp*' \
      -o -name 'libquadmath*' \
      -o -name 'libssp*' \
    \) ! -name '*.dll' -exec rm -f {} +
}

copy_seed_runtime_dlls() {
  local seed_root="$1"
  local final_root="$2"
  local seed_sysroot="${seed_root}/${TARGET_TRIPLE}/sysroot"
  local dll=""

  mkdir -p "${final_root}/bin"
  while IFS= read -r dll; do
    cp -an "$dll" "${final_root}/bin/"
  done < <(
    find "$seed_sysroot" \
      -path '*/lib32/*' -prune \
      -o -type f -name '*.dll' -print | sort
  )
}

prepare_final_tree() {
  local seed_root="$1"
  local final_root="$2"
  local llvm_bin="$3"
  local seed_target_root="${seed_root}/${TARGET_TRIPLE}"

  [[ -d "${seed_target_root}/sysroot" ]] || die "missing seed sysroot: ${seed_target_root}/sysroot"
  [[ -d "${seed_target_root}/sysroot/usr/${TARGET_TRIPLE}/include" ]] || die "missing seed Windows headers"
  [[ -d "${seed_target_root}/sysroot/usr/${TARGET_TRIPLE}/lib" ]] || die "missing seed Windows import libraries"

  mkdir -p "$final_root" "$llvm_bin"
  cp -a "${seed_target_root}/sysroot" "${final_root}/sysroot"
  remove_seed_runtime_artifacts "$final_root"
  copy_seed_runtime_dlls "$seed_root" "$final_root"

  mkdir -p "${final_root}/sysroot/${TARGET_TRIPLE}"
  ln -sfn "../usr/${TARGET_TRIPLE}/include" "${final_root}/sysroot/${TARGET_TRIPLE}/include"
  ln -sfn "../usr/${TARGET_TRIPLE}/lib" "${final_root}/sysroot/${TARGET_TRIPLE}/lib"
}

write_builder_wrapper() {
  local wrapper="$1"
  local compiler="$2"
  local seed_root="$3"
  local final_root="$4"
  local resource_root="$5"
  local cxx_mode="$6"
  local rtlib="${7:-libgcc}"

  cat >"$wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${compiler}" \\
  --target="${TARGET_TRIPLE}" \\
  --sysroot="${final_root}/sysroot" \\
  -resource-dir="${resource_root}" \\
  -B "${final_root}/bin" \\
  -B "${seed_root}/lib/gcc/${TARGET_TRIPLE}/${GCC_VERSION}" \\
  -isystem "${final_root}/sysroot/usr/${TARGET_TRIPLE}/include" \\
  -L "${final_root}/sysroot/${TARGET_TRIPLE}/lib" \\
  -L "${final_root}/sysroot/usr/${TARGET_TRIPLE}/lib" \\
  -L "${final_root}/sysroot/lib" \\
  -L "${seed_root}/lib/gcc/${TARGET_TRIPLE}/${GCC_VERSION}" \\
  --rtlib=${rtlib} \\
EOF

  if [[ "$cxx_mode" == 1 ]]; then
    cat >>"$wrapper" <<EOF
  -isystem "${seed_root}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}" \\
  -isystem "${seed_root}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}/${TARGET_TRIPLE}" \\
  -isystem "${seed_root}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}/backward" \\
  -stdlib=libstdc++ \\
EOF
  fi

  cat >>"$wrapper" <<'EOF'
  "$@"
EOF
  chmod +x "$wrapper"
}

write_final_runtime_wrapper() {
  local wrapper="$1"
  local compiler="$2"
  local final_root="$3"
  local resource_root="$4"
  local cxx_mode="$5"
  local runtime_lib_dir="${resource_root}/lib/${TARGET_TRIPLE}"

  cat >"$wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${compiler}" \\
  --target="${TARGET_TRIPLE}" \\
  --sysroot="${final_root}/sysroot" \\
  -resource-dir="${resource_root}" \\
  -B "${final_root}/bin" \\
  -isystem "${final_root}/sysroot/usr/${TARGET_TRIPLE}/include" \\
  -L "${runtime_lib_dir}" \\
  -L "${final_root}/lib" \\
  -L "${final_root}/sysroot/${TARGET_TRIPLE}/lib" \\
  -L "${final_root}/sysroot/usr/${TARGET_TRIPLE}/lib" \\
  --rtlib=compiler-rt \\
  --unwindlib=libunwind \\
EOF

  if [[ "$cxx_mode" == 1 ]]; then
    cat >>"$wrapper" <<EOF
  -isystem "${final_root}/include/c++/v1" \\
  -stdlib=libc++ \\
EOF
  fi

  cat >>"$wrapper" <<'EOF'
  "$@"
EOF
  chmod +x "$wrapper"
}

configure_cmake() {
  local source_dir="$1"
  local build_dir="$2"
  shift 2

  cmake -S "$source_dir" -B "$build_dir" -G Ninja "$@"
}

build_cmake_target() {
  local build_dir="$1"
  local target="$2"

  cmake --build "$build_dir" --target "$target" --parallel "$JOBS"
}

ensure_output_resource_headers() {
  local output_llvm_root="$1"
  local source_resource="/opt/llvm-${LLVM_VERSION}/lib/clang/${LLVM_RESOURCE_VERSION}"
  local output_resource="${output_llvm_root}/lib/clang/${LLVM_RESOURCE_VERSION}"

  mkdir -p "$output_resource"
  if [[ ! -d "${output_resource}/include" ]]; then
    cp -a "${source_resource}/include" "${output_resource}/include"
  fi
}

build_compiler_rt_builtins_only() {
  local llvm_source_root="$1"
  local seed_root="$2"
  local final_root="$3"
  local output_llvm_root="$4"
  local wrappers="${BUILD_DIR}/${ARCH}/wrappers/compiler-rt-builtins"
  local build_dir="${BUILD_DIR}/${ARCH}/llvm-runtimes/compiler-rt-builtins"
  local resource_root="/opt/llvm-${LLVM_VERSION}/lib/clang/${LLVM_RESOURCE_VERSION}"

  rm -rf "$build_dir"
  mkdir -p "$wrappers" "$build_dir" "${output_llvm_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib/${TARGET_TRIPLE}"
  ensure_output_resource_headers "$output_llvm_root"
  write_builder_wrapper "${wrappers}/clang" "/opt/llvm-${LLVM_VERSION}/bin/clang" "$seed_root" "$final_root" "$resource_root" 0
  write_builder_wrapper "${wrappers}/clang++" "/opt/llvm-${LLVM_VERSION}/bin/clang++" "$seed_root" "$final_root" "$resource_root" 1

  log "Configuring compiler-rt builtins-only for ${TARGET_TRIPLE}"
  configure_cmake "${llvm_source_root}/runtimes" "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_INSTALL_PREFIX="${output_llvm_root}" \
    -DCMAKE_C_COMPILER="${wrappers}/clang" \
    -DCMAKE_CXX_COMPILER="${wrappers}/clang++" \
    -DCMAKE_ASM_COMPILER="${wrappers}/clang" \
    -DCMAKE_AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
    -DCMAKE_NM="/opt/llvm-${LLVM_VERSION}/bin/llvm-nm" \
    -DCMAKE_RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
    -DCMAKE_LINKER="/opt/llvm-${LLVM_VERSION}/bin/ld.lld" \
    -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_SYSROOT="${final_root}/sysroot" \
    "-DCMAKE_FIND_ROOT_PATH=${final_root}/sysroot" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLLVM_PATH="${llvm_source_root}/llvm" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_CRT=OFF \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=OFF \
    "-DCOMPILER_RT_INSTALL_LIBRARY_DIR=${output_llvm_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib"

  log "Building compiler-rt builtins-only for ${TARGET_TRIPLE}"
  build_cmake_target "$build_dir" install
}

build_compiler_rt_full() {
  local llvm_source_root="$1"
  local final_root="$2"
  local output_llvm_root="$3"
  local wrappers="${BUILD_DIR}/${ARCH}/wrappers/compiler-rt-full"
  local build_dir="${BUILD_DIR}/${ARCH}/llvm-runtimes/compiler-rt-full"
  local resource_root="${output_llvm_root}/lib/clang/${LLVM_RESOURCE_VERSION}"
  local runtime_lib_dir="${resource_root}/lib/${TARGET_TRIPLE}"

  rm -rf "$build_dir"
  mkdir -p "$wrappers" "$build_dir" "$runtime_lib_dir"
  ensure_output_resource_headers "$output_llvm_root"
  write_final_runtime_wrapper "${wrappers}/clang" "/opt/llvm-${LLVM_VERSION}/bin/clang" "$final_root" "$resource_root" 0
  write_final_runtime_wrapper "${wrappers}/clang++" "/opt/llvm-${LLVM_VERSION}/bin/clang++" "$final_root" "$resource_root" 1

  log "Configuring compiler-rt full for ${TARGET_TRIPLE}"
  configure_cmake "${llvm_source_root}/runtimes" "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_INSTALL_PREFIX="${output_llvm_root}" \
    -DCMAKE_C_COMPILER="${wrappers}/clang" \
    -DCMAKE_CXX_COMPILER="${wrappers}/clang++" \
    -DCMAKE_ASM_COMPILER="${wrappers}/clang" \
    -DCMAKE_AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
    -DCMAKE_NM="/opt/llvm-${LLVM_VERSION}/bin/llvm-nm" \
    -DCMAKE_RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
    -DCMAKE_LINKER="/opt/llvm-${LLVM_VERSION}/bin/ld.lld" \
    -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_SYSROOT="${final_root}/sysroot" \
    "-DCMAKE_FIND_ROOT_PATH=${final_root}/sysroot;${final_root};${output_llvm_root}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -L${runtime_lib_dir} -L${final_root}/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -L${runtime_lib_dir} -L${final_root}/lib" \
    -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld -L${runtime_lib_dir} -L${final_root}/lib" \
    -DLLVM_PATH="${llvm_source_root}/llvm" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
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
    -DCOMPILER_RT_HAS_Z_TEXT=OFF \
    -DCOMPILER_RT_HAS_VERSION_SCRIPT=OFF \
    -DCOMPILER_RT_HAS_LIBDL=OFF \
    -DCOMPILER_RT_HAS_LIBRT=OFF \
    -DCOMPILER_RT_HAS_LIBPTHREAD=OFF \
    -DCOMPILER_RT_HAS_LIBC=OFF \
    -DSANITIZER_CXX_ABI=libc++ \
    -DSANITIZER_USE_STATIC_CXX_ABI=ON \
    -DSANITIZER_USE_STATIC_LLVM_UNWINDER=ON \
    "-DCOMPILER_RT_INSTALL_LIBRARY_DIR=${output_llvm_root}/lib/clang/${LLVM_RESOURCE_VERSION}/lib"

  log "Building compiler-rt full for ${TARGET_TRIPLE}"
  build_cmake_target "$build_dir" install
}

build_cxx_runtimes() {
  local llvm_source_root="$1"
  local seed_root="$2"
  local final_root="$3"
  local output_llvm_root="$4"
  local wrappers="${BUILD_DIR}/${ARCH}/wrappers/cxx-runtimes"
  local build_dir="${BUILD_DIR}/${ARCH}/llvm-runtimes/cxx"
  local resource_root="${output_llvm_root}/lib/clang/${LLVM_RESOURCE_VERSION}"
  local runtime_lib_dir="${resource_root}/lib/${TARGET_TRIPLE}"

  rm -rf "$build_dir"
  mkdir -p "$wrappers" "$build_dir" "$runtime_lib_dir"
  ensure_output_resource_headers "$output_llvm_root"
  write_builder_wrapper "${wrappers}/clang" "/opt/llvm-${LLVM_VERSION}/bin/clang" "$seed_root" "$final_root" "$resource_root" 0 compiler-rt
  write_builder_wrapper "${wrappers}/clang++" "/opt/llvm-${LLVM_VERSION}/bin/clang++" "$seed_root" "$final_root" "$resource_root" 1 compiler-rt

  log "Configuring libunwind/libc++abi/libc++ for ${TARGET_TRIPLE}"
  configure_cmake "${llvm_source_root}/runtimes" "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_INSTALL_PREFIX="${final_root}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_INCLUDEDIR=include \
    -DCMAKE_C_COMPILER="${wrappers}/clang" \
    -DCMAKE_CXX_COMPILER="${wrappers}/clang++" \
    -DCMAKE_ASM_COMPILER="${wrappers}/clang" \
    -DCMAKE_AR="/opt/llvm-${LLVM_VERSION}/bin/llvm-ar" \
    -DCMAKE_NM="/opt/llvm-${LLVM_VERSION}/bin/llvm-nm" \
    -DCMAKE_RANLIB="/opt/llvm-${LLVM_VERSION}/bin/llvm-ranlib" \
    -DCMAKE_LINKER="/opt/llvm-${LLVM_VERSION}/bin/ld.lld" \
    -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}" \
    -DCMAKE_SYSROOT="${final_root}/sysroot" \
    "-DCMAKE_FIND_ROOT_PATH=${final_root}/sysroot;${final_root};${output_llvm_root}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -L${runtime_lib_dir} -L${final_root}/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -L${runtime_lib_dir} -L${final_root}/lib" \
    -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld -L${runtime_lib_dir} -L${final_root}/lib" \
    -DLLVM_PATH="${llvm_source_root}/llvm" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
    -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBUNWIND_ENABLE_SHARED=ON \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBUNWIND_USE_COMPILER_RT=ON \
    -DLIBUNWIND_HAS_C_LIB=OFF \
    -DLIBUNWIND_HAS_DL_LIB=OFF \
    -DLIBUNWIND_HAS_GCC_LIB=OFF \
    -DLIBUNWIND_HAS_GCC_S_LIB=OFF \
    -DLIBUNWIND_HAS_PTHREAD_LIB=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF \
    -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXXABI_HAS_C_LIB=OFF \
    -DLIBCXXABI_HAS_DL_LIB=OFF \
    -DLIBCXXABI_HAS_GCC_LIB=OFF \
    -DLIBCXXABI_HAS_GCC_S_LIB=OFF \
    -DLIBCXXABI_HAS_PTHREAD_LIB=OFF \
    -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF \
    -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXX_ENABLE_SHARED=ON \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_HAS_GCC_LIB=OFF \
    -DLIBCXX_HAS_GCC_S_LIB=OFF \
    -DLIBCXX_HAS_PTHREAD_LIB=OFF \
    -DLIBCXX_HAS_RT_LIB=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON

  log "Building libunwind/libc++abi/libc++ for ${TARGET_TRIPLE}"
  build_cmake_target "$build_dir" install
}

write_clang_cfg() {
  local cfg_path="$1"
  local add_cxx="$2"

  cat >"$cfg_path" <<EOF
# Default Windows GNU cross configuration for ${TARGET_TRIPLE}.
--target=${TARGET_TRIPLE}
--sysroot=<CFGDIR>/../../${TARGET_TRIPLE}/sysroot
-resource-dir=<CFGDIR>/../lib/clang/${LLVM_RESOURCE_VERSION}
-B
<CFGDIR>/../../${TARGET_TRIPLE}/bin
EOF

  if [[ "$add_cxx" == 1 ]]; then
    cat >>"$cfg_path" <<EOF
-stdlib=libc++
-isystem
<CFGDIR>/../../${TARGET_TRIPLE}/include/c++/v1
EOF
  fi

  cat >>"$cfg_path" <<EOF
-isystem
<CFGDIR>/../../${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/include
-L
<CFGDIR>/../../${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/lib
-L
<CFGDIR>/../lib/clang/${LLVM_RESOURCE_VERSION}/lib/${TARGET_TRIPLE}
-L
<CFGDIR>/../../${TARGET_TRIPLE}/lib
--rtlib=compiler-rt
--unwindlib=libunwind
EOF
}

write_cmake_toolchain() {
  local toolchain_path="$1"

  cat >"$toolchain_path" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER /opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-gcc)
set(CMAKE_CXX_COMPILER /opt/llvm-${LLVM_VERSION}/bin/${TARGET_TRIPLE}-clang-g++)

set(CMAKE_SYSROOT /opt/${TARGET_TRIPLE}/sysroot)
set(CMAKE_FIND_ROOT_PATH /opt/${TARGET_TRIPLE}/sysroot /opt/${TARGET_TRIPLE})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

ARCH=""
JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build"
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch=*)
      ARCH="${1#*=}"
      ;;
    --arch)
      shift
      [[ $# -gt 0 ]] || die "--arch requires a value"
      ARCH="$1"
      ;;
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

[[ -n "$ARCH" ]] || die "--arch is required"
ARCH="$(normalize_arch "$ARCH")"
OUT_DIR="${OUT_DIR:-/work/out/${ARCH}}"

require_command curl
require_command cmake
require_command ninja
require_command make
require_command tar
require_command bash

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"
trap restore_host_access EXIT INT TERM

log "stage-mingw64 container build"
log "host arch: ${ARCH}"
log "target triple: ${TARGET_TRIPLE}"
log "out dir: ${OUT_DIR}"

download_archive "$MINGW_ARCHIVE_URL" "$MINGW_ARCHIVE_NAME"
download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
download_archive "$BINUTILS_ARCHIVE_URL" "$BINUTILS_ARCHIVE_NAME"

EXTRACT_DIR="${BUILD_DIR}/${ARCH}/mingw-extract"
SEED_ROOT="${BUILD_DIR}/${ARCH}/mingw-seed"
FINAL_ROOT="${OUT_DIR}/opt/${TARGET_TRIPLE}"
OUTPUT_LLVM_ROOT="${OUT_DIR}/opt/llvm-${LLVM_VERSION}"
LLVM_BIN="${OUTPUT_LLVM_ROOT}/bin"

rm -rf "$EXTRACT_DIR" "$SEED_ROOT" "$OUT_DIR"
mkdir -p "$EXTRACT_DIR" "$SEED_ROOT" "$LLVM_BIN"
tar -xf "${CACHE_DIR}/${MINGW_ARCHIVE_NAME}" -C "$EXTRACT_DIR"

MINGW_ROOT="$(find_mingw_root "$EXTRACT_DIR")" || die "could not find MinGW GCC root in archive"
cp -a "${MINGW_ROOT}/." "$SEED_ROOT/"

PACKAGE_TARGET_TRIPLE="$(detect_package_triple "$SEED_ROOT")" || die "could not detect package GCC target triple under ${SEED_ROOT}"
GCC_LIB_ROOT="${SEED_ROOT}/lib/gcc/${PACKAGE_TARGET_TRIPLE}"
[[ -d "$GCC_LIB_ROOT" ]] || die "missing package GCC runtime lib root: ${GCC_LIB_ROOT}"
GCC_VERSION="$(find "$GCC_LIB_ROOT" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | sort | tail -n 1)"
[[ -n "$GCC_VERSION" ]] || die "could not detect GCC runtime version under ${GCC_LIB_ROOT}"
normalize_seed_triple "$SEED_ROOT" "$PACKAGE_TARGET_TRIPLE"

prepare_final_tree "$SEED_ROOT" "$FINAL_ROOT" "$LLVM_BIN"

bash /work/mount_root/build_binutils.sh \
  --arch="$ARCH" \
  --jobs="$JOBS" \
  --cache-dir="$CACHE_DIR" \
  --build-dir="$BUILD_DIR" \
  --prefix="$FINAL_ROOT"

LLVM_SOURCE_ROOT="$(extract_llvm_source)"
build_compiler_rt_builtins_only "$LLVM_SOURCE_ROOT" "$SEED_ROOT" "$FINAL_ROOT" "$OUTPUT_LLVM_ROOT"
build_cxx_runtimes "$LLVM_SOURCE_ROOT" "$SEED_ROOT" "$FINAL_ROOT" "$OUTPUT_LLVM_ROOT"
build_compiler_rt_full "$LLVM_SOURCE_ROOT" "$FINAL_ROOT" "$OUTPUT_LLVM_ROOT"

ln -sfn clang "${LLVM_BIN}/${TARGET_TRIPLE}-clang-gcc"
ln -sfn clang++ "${LLVM_BIN}/${TARGET_TRIPLE}-clang-g++"
write_clang_cfg "${LLVM_BIN}/${TARGET_TRIPLE}-clang-gcc.cfg" 0
write_clang_cfg "${LLVM_BIN}/${TARGET_TRIPLE}-clang-g++.cfg" 1
write_cmake_toolchain "${FINAL_ROOT}/toolchain.cmake"

cat >"${FINAL_ROOT}/README.stage-mingw64" <<EOF
This overlay installs a Windows GNU target runtime for ${TARGET_TRIPLE}.

Host output arch: ${ARCH}
Target triple: ${TARGET_TRIPLE}
Seed GCC runtime version: ${GCC_VERSION}

The prebuilt GCC/MinGW package is used only as a runtime build seed. The final
overlay keeps the target sysroot, binutils built from source, clang cfg files,
and LLVM runtimes.
EOF

log "stage-mingw64 container build ok: ${OUT_DIR}"
