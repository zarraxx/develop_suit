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

  if [[ ! -f "${extract_dir}/clang/CMakeLists.txt" || ! -f "${extract_dir}/lld/CMakeLists.txt" || ! -f "${extract_dir}/lldb/CMakeLists.txt" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "${CACHE_DIR}/${LLVM_ARCHIVE_NAME}" -C "$extract_dir" --strip-components=1
  fi

  [[ -f "${extract_dir}/clang/CMakeLists.txt" ]] || die "invalid clang source tree: ${extract_dir}"
  [[ -f "${extract_dir}/lld/CMakeLists.txt" ]] || die "invalid lld source tree: ${extract_dir}"
  [[ -f "${extract_dir}/lldb/CMakeLists.txt" ]] || die "invalid lldb source tree: ${extract_dir}"
  [[ -f "${extract_dir}/clang-tools-extra/CMakeLists.txt" ]] || die "invalid clang-tools-extra source tree: ${extract_dir}"
  printf '%s\n' "$extract_dir"
}

apply_source_patches() {
  local patch_dir="${PATCH_DIR:-/work/mount_root/patch}"
  local patch_file=""

  [[ -d "$patch_dir" ]] || return 0

  shopt -s nullglob
  for patch_file in "${patch_dir}/llvm-${LLVM_VERSION}-"*.patch; do
    log "Applying $(basename "$patch_file")"
    patch -d "$LLVM_SOURCE_ROOT" -p1 <"$patch_file"
  done
  shopt -u nullglob
}

copy_prefix() {
  local source_dir="$1"
  local dest_dir="$2"

  [[ -d "$source_dir" ]] || die "prefix directory not found: ${source_dir}"
  mkdir -p "$dest_dir"
  cp -a "${source_dir}/." "$dest_dir/"
}

copy_prefix_if_exists() {
  local source_dir="$1"
  local dest_dir="$2"

  [[ -d "$source_dir" ]] || return 0
  copy_prefix "$source_dir" "$dest_dir"
}

assemble_sdk_prefix() {
  local runtime_dir=""

  rm -rf "${SDK_PREFIX:?}/"*
  mkdir -p "$SDK_PREFIX"

  log "Copying target llvmsdk into final clang prefix"
  copy_prefix "$LLVMSDK_PREFIX" "$SDK_PREFIX"

  log "Overlaying libcxx runtime packages"
  shopt -s nullglob
  for runtime_dir in "${LIBCXX_INPUT_ROOT}"/*; do
    [[ -d "$runtime_dir" ]] || continue
    copy_prefix "$runtime_dir" "$SDK_PREFIX"
  done
  shopt -u nullglob
}

copy_host_runtime_shared_libraries_to_lib() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  local runtime_lib_dir="${SDK_PREFIX}/lib/${TARGET_TRIPLE}"

  [[ -d "$runtime_lib_dir" ]] || die "missing host runtime library directory: ${runtime_lib_dir}"
  mkdir -p "${SDK_PREFIX}/lib"

  shopt -s nullglob
  cp -a "${runtime_lib_dir}"/libc++.so* "${SDK_PREFIX}/lib/" 2>/dev/null || true
  cp -a "${runtime_lib_dir}"/libc++abi.so* "${SDK_PREFIX}/lib/" 2>/dev/null || true
  cp -a "${runtime_lib_dir}"/libunwind.so* "${SDK_PREFIX}/lib/" 2>/dev/null || true
  shopt -u nullglob

  [[ -e "${SDK_PREFIX}/lib/libc++.so.1" || -e "${SDK_PREFIX}/lib/libc++.so" ]] \
    || die "missing copied host libc++ shared library"
  [[ -e "${SDK_PREFIX}/lib/libc++abi.so.1" || -e "${SDK_PREFIX}/lib/libc++abi.so" ]] \
    || die "missing copied host libc++abi shared library"
  [[ -e "${SDK_PREFIX}/lib/libunwind.so.1" || -e "${SDK_PREFIX}/lib/libunwind.so" ]] \
    || die "missing copied host libunwind shared library"
}

copy_mingw64_sysroot_to_prefix() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  [[ -d "$MINGW_SYSROOT_PREFIX" ]] || die "missing mingw64 sysroot prefix: ${MINGW_SYSROOT_PREFIX}"

  local source_sysroot_target="${MINGW_SYSROOT_PREFIX}/sysroot/usr/${TARGET_TRIPLE}"
  local source_runtime_lib_dir="${MINGW_SYSROOT_PREFIX}/lib/${TARGET_TRIPLE}"
  local builtins_source="${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/lib/${TARGET_TRIPLE}/libclang_rt.builtins.a"
  local builtins_dest="${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/lib/windows/libclang_rt.builtins-x86_64.a"

  [[ -d "${source_sysroot_target}/include" ]] || die "missing mingw64 CRT include dir: ${source_sysroot_target}/include"
  [[ -d "${source_sysroot_target}/lib" ]] || die "missing mingw64 CRT lib dir: ${source_sysroot_target}/lib"

  log "Overlaying mingw64 native sysroot layout into final clang prefix"
  mkdir -p \
    "${SDK_PREFIX}/bin" \
    "${SDK_PREFIX}/include" \
    "${SDK_PREFIX}/lib" \
    "${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/lib/windows"

  copy_prefix "${source_sysroot_target}/include" "${SDK_PREFIX}/include"
  copy_prefix "${source_sysroot_target}/lib" "${SDK_PREFIX}/lib"
  copy_prefix_if_exists "${MINGW_SYSROOT_PREFIX}/include" "${SDK_PREFIX}/include"
  copy_prefix_if_exists "${MINGW_SYSROOT_PREFIX}/lib" "${SDK_PREFIX}/lib"
  rm -rf "${SDK_PREFIX}/lib/bfd-plugins"
  copy_prefix_if_exists "$source_runtime_lib_dir" "${SDK_PREFIX}/lib"

  if [[ -f "$builtins_source" ]]; then
    cp -f "$builtins_source" "$builtins_dest"
  fi

  find "${MINGW_SYSROOT_PREFIX}/bin" "${MINGW_SYSROOT_PREFIX}/sysroot" \
    -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
  rm -rf "${SDK_PREFIX:?}/${TARGET_TRIPLE}"
}

strip_mingw64_crt_debug_sections() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  local strip_tool="${PREBUILT_LLVM_ROOT}/bin/llvm-strip"
  local path=""
  local count=0

  [[ -x "$strip_tool" ]] || die "missing llvm-strip: ${strip_tool}"

  log "Stripping debug sections from bundled mingw64 CRT objects and static archives"
  while IFS= read -r -d '' path; do
    "$strip_tool" --strip-debug "$path"
    count=$((count + 1))
  done < <(
    find "${SDK_PREFIX}/lib" \
      \( -type f -name '*.o' -o -type f -name '*.a' ! -name '*.dll.a' \) \
      -print0
  )
  log "Stripped mingw64 CRT debug sections from ${count} files"
}

llvm_target_arch_name_for_arch() {
  case "$1" in
    x86_64) printf '%s\n' X86 ;;
    aarch64) printf '%s\n' AArch64 ;;
    riscv64) printf '%s\n' RISCV ;;
    loongarch64) printf '%s\n' LoongArch ;;
    *) die "unsupported LLVM target arch: $1" ;;
  esac
}

set_stage_llvm_policy_args() {
  LLVM_TARGET_ARCH_NAME="$(llvm_target_arch_name_for_arch "$ARCH")"

  LLVM_VCS_VERSION_ARGS=(
    "-DLLVM_FORCE_VC_REPOSITORY=${LLVM_VC_REPOSITORY}"
    "-DLLVM_FORCE_VC_REVISION=${BUILD_DATE}"
  )

  STAGE_LLVM_BASE_ARGS=(
    "-DLLVM_TARGETS_TO_BUILD=${LLVM_TARGETS}"
    "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=${LLVM_EXPERIMENTAL_TARGETS}"
    "-DLLVM_HOST_TRIPLE=${TARGET_TRIPLE}"
    "-DLLVM_TARGET_ARCH=${LLVM_TARGET_ARCH_NAME}"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=${TARGET_TRIPLE}"
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_INSTALL_UTILS=ON
    -DLLVM_ENABLE_TERMINFO=OFF
    -DLLVM_ENABLE_LIBXML2=ON
    -DLLVM_ENABLE_LIBCXX=ON
    -DLLVM_ENABLE_ZLIB=ON
    -DLLVM_ENABLE_ZSTD=ON
    -DLLVM_ENABLE_RTTI=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
  )

  STAGE_CLANG_POLICY_ARGS=(
    -DCLANG_LINK_CLANG_DYLIB=ON
    -DCLANG_BUILD_TOOLS=ON
    -DCLANG_DEFAULT_LINKER=lld
    -DCLANG_DEFAULT_CXX_STDLIB=libc++
    -DCLANG_DEFAULT_RTLIB=compiler-rt
    -DCLANG_DEFAULT_UNWINDLIB=libunwind
    -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy
    -DCLANG_ENABLE_LIBXML2=ON
    -DCLANG_ENABLE_STATIC_ANALYZER=ON
    -DCLANG_ENABLE_BOOTSTRAP=OFF
    -DCLANG_INCLUDE_TESTS=OFF
    -DCLANG_INCLUDE_DOCS=OFF
    -DCLANG_BUILD_EXAMPLES=OFF
    -DCLANG_TOOLS_EXTRA_INCLUDE_DOCS=OFF
  )

  STAGE_LLD_POLICY_ARGS=(
    -DLLD_DEFAULT_LD_LLD_IS_MINGW=ON
    -DLLD_BUILD_TOOLS=ON
  )

  STAGE_LLD_LLVM_ARGS=(
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_ENABLE_LIBXML2=ON
    -DLLVM_ENABLE_LIBCXX=ON
    -DLLVM_ENABLE_ZLIB=ON
    -DLLVM_ENABLE_ZSTD=ON
    -DLLVM_ENABLE_RTTI=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
  )
}

make_native_tool_dir() {
  local native_clang_tblgen="${NATIVE_CLANG_TOOLS_BUILD_DIR}/bin/clang-tblgen"
  local native_lldb_tblgen="${NATIVE_LLDB_TOOLS_BUILD_DIR}/bin/lldb-tblgen"
  local native_pseudo_gen="${NATIVE_CLANG_TOOLS_BUILD_DIR}/bin/clang-pseudo-gen"
  local native_confusable_gen="${NATIVE_TOOL_DIR}/bin/clang-tidy-confusable-chars-gen"
  local native_build_cc="${PREBUILT_LLVM_ROOT}/bin/x86_64-unknown-linux-gnu-clang-gcc"
  local native_build_cxx="${PREBUILT_LLVM_ROOT}/bin/x86_64-unknown-linux-gnu-clang-g++"
  local confusable_gen_src="${LLVM_SOURCE_ROOT}/clang-tools-extra/clang-tidy/misc/ConfusableTable/BuildConfusableTable.cpp"
  local build_targets=(clang-tblgen)
  local needs_pseudo_gen=0

  if [[ ! -x "$native_build_cc" ]]; then
    native_build_cc="${PREBUILT_LLVM_ROOT}/bin/clang"
  fi
  if [[ ! -x "$native_build_cxx" ]]; then
    native_build_cxx="${PREBUILT_LLVM_ROOT}/bin/clang++"
  fi

  rm -rf "$NATIVE_TOOL_DIR"
  mkdir -p "${NATIVE_TOOL_DIR}/bin"

  ln -s "${NATIVE_LLVMSDK_PREFIX}/bin/llvm-tblgen" "${NATIVE_TOOL_DIR}/bin/llvm-tblgen"
  ln -s "${NATIVE_LLVMSDK_PREFIX}/bin/llvm-config" "${NATIVE_TOOL_DIR}/bin/llvm-config"
  ln -s "${NATIVE_LLVMSDK_PREFIX}/bin/llvm-nm" "${NATIVE_TOOL_DIR}/bin/llvm-nm"
  ln -s "${NATIVE_LLVMSDK_PREFIX}/bin/llvm-readobj" "${NATIVE_TOOL_DIR}/bin/llvm-readobj"

  if [[ -f "${LLVM_SOURCE_ROOT}/clang-tools-extra/pseudo/gen/CMakeLists.txt" ]]; then
    needs_pseudo_gen=1
    build_targets+=(clang-pseudo-gen)
  fi

  if [[ ! -x "$native_clang_tblgen" || ( "$needs_pseudo_gen" == "1" && ! -x "$native_pseudo_gen" ) ]]; then
    rm -rf "$NATIVE_CLANG_TOOLS_BUILD_DIR"
    mkdir -p "$NATIVE_CLANG_TOOLS_BUILD_DIR"

    log "Configuring native clang host tools"
    cmake -S "${LLVM_SOURCE_ROOT}/clang" -B "$NATIVE_CLANG_TOOLS_BUILD_DIR" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$native_build_cc" \
      -DCMAKE_CXX_COMPILER="$native_build_cxx" \
      -DCMAKE_LINKER="${PREBUILT_LLVM_ROOT}/bin/ld.lld" \
      "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -B${PREBUILT_LLVM_ROOT}/bin" \
      "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -B${PREBUILT_LLVM_ROOT}/bin" \
      "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld -B${PREBUILT_LLVM_ROOT}/bin" \
      "-DCMAKE_PREFIX_PATH=${NATIVE_LLVMSDK_PREFIX}" \
      "-DLLVM_DIR=${NATIVE_LLVMSDK_PREFIX}/lib/cmake/llvm" \
      "-DLLVM_TABLEGEN=${NATIVE_LLVMSDK_PREFIX}/bin/llvm-tblgen" \
      "-DLLVM_CONFIG_PATH=${NATIVE_LLVMSDK_PREFIX}/bin/llvm-config" \
      "-DLLVM_TARGETS_TO_BUILD=${LLVM_TARGETS}" \
      "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=${LLVM_EXPERIMENTAL_TARGETS}" \
      "-DLLVM_EXTERNAL_CLANG_TOOLS_EXTRA_SOURCE_DIR=${LLVM_SOURCE_ROOT}/clang-tools-extra" \
      "${LLVM_VCS_VERSION_ARGS[@]}" \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DCLANG_BUILD_TOOLS=ON \
      -DCLANG_INCLUDE_TESTS=OFF \
      -DCLANG_INCLUDE_DOCS=OFF \
      -DCLANG_TOOLS_EXTRA_INCLUDE_DOCS=OFF \
      -DCLANG_BUILD_EXAMPLES=OFF \
      -DCLANG_ENABLE_ARCMT=OFF \
      -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
      -DCLANG_ENABLE_BOOTSTRAP=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_DOCS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF

    log "Building native clang host tools"
    cmake --build "$NATIVE_CLANG_TOOLS_BUILD_DIR" --parallel "$JOBS" --target "${build_targets[@]}"
  fi

  [[ -x "$native_clang_tblgen" ]] || die "missing native clang-tblgen"
  ln -s "$native_clang_tblgen" "${NATIVE_TOOL_DIR}/bin/clang-tblgen"
  if [[ "$needs_pseudo_gen" == "1" ]]; then
    [[ -x "$native_pseudo_gen" ]] || die "missing native clang-pseudo-gen"
    ln -s "$native_pseudo_gen" "${NATIVE_TOOL_DIR}/bin/clang-pseudo-gen"
  fi

  if [[ ! -x "$native_confusable_gen" ]]; then
    local llvm_cxxflags=()
    local llvm_ldflags=()
    local llvm_libs=()

    [[ -f "$confusable_gen_src" ]] || die "missing clang-tidy confusable table generator source"
    mapfile -t llvm_cxxflags < <("${NATIVE_LLVMSDK_PREFIX}/bin/llvm-config" --cxxflags | xargs -n1 printf '%s\n')
    mapfile -t llvm_ldflags < <("${NATIVE_LLVMSDK_PREFIX}/bin/llvm-config" --ldflags | xargs -n1 printf '%s\n')
    mapfile -t llvm_libs < <("${NATIVE_LLVMSDK_PREFIX}/bin/llvm-config" --libs support --system-libs | xargs -n1 printf '%s\n')

    log "Building native clang-tidy-confusable-chars-gen"
    "$native_build_cxx" \
      "${llvm_cxxflags[@]}" \
      -std=c++17 \
      "$confusable_gen_src" \
      -o "$native_confusable_gen" \
      "${llvm_ldflags[@]}" \
      "${llvm_libs[@]}" \
      -Wl,-rpath,"${NATIVE_LLVMSDK_PREFIX}/lib"
  fi

  [[ -x "$native_confusable_gen" ]] || die "missing native clang-tidy-confusable-chars-gen"

  if [[ ! -x "$native_lldb_tblgen" ]]; then
    rm -rf "$NATIVE_LLDB_TOOLS_BUILD_DIR"
    mkdir -p "$NATIVE_LLDB_TOOLS_BUILD_DIR"

    log "Configuring native lldb host tools"
    cmake -S "${LLVM_SOURCE_ROOT}/lldb" -B "$NATIVE_LLDB_TOOLS_BUILD_DIR" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$native_build_cc" \
      -DCMAKE_CXX_COMPILER="$native_build_cxx" \
      -DCMAKE_LINKER="${PREBUILT_LLVM_ROOT}/bin/ld.lld" \
      "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -B${PREBUILT_LLVM_ROOT}/bin" \
      "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -B${PREBUILT_LLVM_ROOT}/bin" \
      "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld -B${PREBUILT_LLVM_ROOT}/bin" \
      "-DCMAKE_PREFIX_PATH=${NATIVE_LLVMSDK_PREFIX};${NATIVE_STAGE0_PREFIX}" \
      "-DLLVM_DIR=${NATIVE_LLVMSDK_PREFIX}/lib/cmake/llvm" \
      "-DClang_DIR=${NATIVE_STAGE0_PREFIX}/lib/cmake/clang" \
      "-DLLVM_TABLEGEN=${NATIVE_LLVMSDK_PREFIX}/bin/llvm-tblgen" \
      "-DLLVM_CONFIG_PATH=${NATIVE_LLVMSDK_PREFIX}/bin/llvm-config" \
      "-DLLVM_EXTERNAL_CLANG_SOURCE_DIR=${LLVM_SOURCE_ROOT}/clang" \
      -DPython3_EXECUTABLE=/usr/bin/python3 \
      "${LLVM_VCS_VERSION_ARGS[@]}" \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DLLDB_ENABLE_PYTHON=OFF \
      -DLLDB_ENABLE_LUA=OFF \
      -DLLDB_ENABLE_LIBEDIT=OFF \
      -DLLDB_ENABLE_CURSES=OFF \
      -DLLDB_ENABLE_LZMA=OFF \
      -DLLDB_ENABLE_LIBXML2=ON \
      -DLLDB_ENABLE_PROTOCOL_SERVERS=OFF \
      -DLLDB_ENABLE_FBSDVMCORE=OFF \
      -DLLDB_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_DOCS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF

    log "Building native lldb host tools"
    cmake --build "$NATIVE_LLDB_TOOLS_BUILD_DIR" --parallel "$JOBS" --target lldb-tblgen
  fi

  [[ -x "$native_lldb_tblgen" ]] || die "missing native lldb-tblgen"
  ln -s "$native_lldb_tblgen" "${NATIVE_TOOL_DIR}/bin/lldb-tblgen"
}

build_clang_and_tools() {
  rm -rf "$CLANG_BUILD_DIR"
  mkdir -p "$CLANG_BUILD_DIR"

  log "Configuring clang and clang-tools-extra for ${TARGET_TRIPLE}"
  cmake -S "${LLVM_SOURCE_ROOT}/clang" -B "$CLANG_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
    -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_C_COMPILER="${NATIVE_STAGE0_PREFIX}/bin/clang" \
    -DCMAKE_CXX_COMPILER="${NATIVE_STAGE0_PREFIX}/bin/clang++" \
    -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    "-DCMAKE_FIND_ROOT_PATH=${SDK_PREFIX};${TARGET_ROOT};${SYSROOT}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
    "${CMAKE_RPATH_ARGS[@]}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE \
    -DCMAKE_AR="${PREBUILT_LLVM_ROOT}/bin/llvm-ar" \
    -DCMAKE_NM="${PREBUILT_LLVM_ROOT}/bin/llvm-nm" \
    -DCMAKE_OBJCOPY="${PREBUILT_LLVM_ROOT}/bin/llvm-objcopy" \
    -DCMAKE_RANLIB="${PREBUILT_LLVM_ROOT}/bin/llvm-ranlib" \
    -DCMAKE_STRIP="${PREBUILT_LLVM_ROOT}/bin/llvm-strip" \
    "-DCMAKE_C_FLAGS=${TARGET_C_FLAGS}" \
    "-DCMAKE_CXX_FLAGS=${TARGET_CXX_FLAGS}" \
    "-DCMAKE_EXE_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "-DCMAKE_SHARED_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "-DCMAKE_MODULE_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "${CMAKE_STANDARD_LIBRARY_ARGS[@]}" \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    "-DLLVM_DIR=${SDK_PREFIX}/lib/cmake/llvm" \
    "-DLLVM_NATIVE_TOOL_DIR=${NATIVE_TOOL_DIR}/bin" \
    "-DLLVM_TABLEGEN=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DLLVM_TABLEGEN_EXE=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DLLVM_TABLEGEN_TARGET=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DCLANG_TABLEGEN=${NATIVE_TOOL_DIR}/bin/clang-tblgen" \
    "-DCLANG_TABLEGEN_EXE=${NATIVE_TOOL_DIR}/bin/clang-tblgen" \
    "-DCLANG_TABLEGEN_TARGET=${NATIVE_TOOL_DIR}/bin/clang-tblgen" \
    "-DCLANG_PSEUDO_GEN=${NATIVE_TOOL_DIR}/bin/clang-pseudo-gen" \
    "-DCLANG_TIDY_CONFUSABLE_CHARS_GEN=${NATIVE_TOOL_DIR}/bin/clang-tidy-confusable-chars-gen" \
    "-DLLVM_CONFIG_PATH=${NATIVE_TOOL_DIR}/bin/llvm-config" \
    "-DClang_NATIVE_BUILD=${NATIVE_CLANG_TOOLS_BUILD_DIR}" \
    "-DClang_NATIVE_STAMP=${NATIVE_CLANG_TOOLS_BUILD_DIR}-stamps" \
    "-DLLVM_EXTERNAL_CLANG_TOOLS_EXTRA_SOURCE_DIR=${LLVM_SOURCE_ROOT}/clang-tools-extra" \
    "${LLVM_VCS_VERSION_ARGS[@]}" \
    "${STAGE_LLVM_BASE_ARGS[@]}" \
    "${STAGE_CLANG_POLICY_ARGS[@]}"

  log "Installing clang and clang-tools-extra"
  cmake --build "$CLANG_BUILD_DIR" --parallel "$JOBS" --target install
}

build_lld() {
  rm -rf "$LLD_BUILD_DIR"
  mkdir -p "$LLD_BUILD_DIR"

  log "Configuring lld for ${TARGET_TRIPLE}"
  cmake -S "${LLVM_SOURCE_ROOT}/lld" -B "$LLD_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
    -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_C_COMPILER="${NATIVE_STAGE0_PREFIX}/bin/clang" \
    -DCMAKE_CXX_COMPILER="${NATIVE_STAGE0_PREFIX}/bin/clang++" \
    -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    "-DCMAKE_FIND_ROOT_PATH=${SDK_PREFIX};${TARGET_ROOT};${SYSROOT}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
    "${CMAKE_RPATH_ARGS[@]}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE \
    -DCMAKE_AR="${PREBUILT_LLVM_ROOT}/bin/llvm-ar" \
    -DCMAKE_NM="${PREBUILT_LLVM_ROOT}/bin/llvm-nm" \
    -DCMAKE_OBJCOPY="${PREBUILT_LLVM_ROOT}/bin/llvm-objcopy" \
    -DCMAKE_RANLIB="${PREBUILT_LLVM_ROOT}/bin/llvm-ranlib" \
    -DCMAKE_STRIP="${PREBUILT_LLVM_ROOT}/bin/llvm-strip" \
    "-DCMAKE_C_FLAGS=${TARGET_C_FLAGS}" \
    "-DCMAKE_CXX_FLAGS=${TARGET_CXX_FLAGS}" \
    "-DCMAKE_EXE_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "-DCMAKE_SHARED_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "-DCMAKE_MODULE_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "${CMAKE_STANDARD_LIBRARY_ARGS[@]}" \
    "-DLLVM_DIR=${SDK_PREFIX}/lib/cmake/llvm" \
    "-DLLVM_TABLEGEN_EXE=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DLLVM_TABLEGEN_TARGET=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "${LLVM_VCS_VERSION_ARGS[@]}" \
    "${STAGE_LLD_LLVM_ARGS[@]}" \
    "${STAGE_LLD_POLICY_ARGS[@]}"

  log "Installing lld"
  cmake --build "$LLD_BUILD_DIR" --parallel "$JOBS" --target install
}

build_lldb() {
  rm -rf "$LLDB_BUILD_DIR"
  mkdir -p "$LLDB_BUILD_DIR"

  log "Configuring lldb for ${TARGET_TRIPLE}"
  cmake -S "${LLVM_SOURCE_ROOT}/lldb" -B "$LLDB_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
    -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_C_COMPILER="${NATIVE_STAGE0_PREFIX}/bin/clang" \
    -DCMAKE_CXX_COMPILER="${NATIVE_STAGE0_PREFIX}/bin/clang++" \
    -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    "-DCMAKE_FIND_ROOT_PATH=${SDK_PREFIX};${TARGET_ROOT};${SYSROOT}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    "-DCMAKE_PREFIX_PATH=${SDK_PREFIX}" \
    "${CMAKE_RPATH_ARGS[@]}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE \
    -DCMAKE_AR="${PREBUILT_LLVM_ROOT}/bin/llvm-ar" \
    -DCMAKE_NM="${PREBUILT_LLVM_ROOT}/bin/llvm-nm" \
    -DCMAKE_OBJCOPY="${PREBUILT_LLVM_ROOT}/bin/llvm-objcopy" \
    -DCMAKE_RANLIB="${PREBUILT_LLVM_ROOT}/bin/llvm-ranlib" \
    -DCMAKE_STRIP="${PREBUILT_LLVM_ROOT}/bin/llvm-strip" \
    "-DCMAKE_C_FLAGS=${TARGET_C_FLAGS}" \
    "-DCMAKE_CXX_FLAGS=${TARGET_CXX_FLAGS}" \
    "-DCMAKE_EXE_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "-DCMAKE_SHARED_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "-DCMAKE_MODULE_LINKER_FLAGS=${TARGET_LINK_FLAGS}" \
    "${CMAKE_STANDARD_LIBRARY_ARGS[@]}" \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    "-DLLVM_DIR=${SDK_PREFIX}/lib/cmake/llvm" \
    "-DClang_DIR=${SDK_PREFIX}/lib/cmake/clang" \
    "-DLLVM_TABLEGEN_EXE=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DLLVM_TABLEGEN_TARGET=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DLLVM_TABLEGEN=${NATIVE_TOOL_DIR}/bin/llvm-tblgen" \
    "-DLLDB_TABLEGEN_EXE=${NATIVE_TOOL_DIR}/bin/lldb-tblgen" \
    "-DLLDB_TABLEGEN_TARGET=${NATIVE_TOOL_DIR}/bin/lldb-tblgen" \
    "-DLLVM_CONFIG_PATH=${NATIVE_TOOL_DIR}/bin/llvm-config" \
    "-DLLVM_EXTERNAL_CLANG_SOURCE_DIR=${LLVM_SOURCE_ROOT}/clang" \
    "-DLLDB_EXTERNAL_CLANG_RESOURCE_DIR=${RESOURCE_DIR}" \
    "${LLVM_VCS_VERSION_ARGS[@]}" \
    "${STAGE_LLD_LLVM_ARGS[@]}" \
    -DLLDB_ENABLE_PYTHON=OFF \
    -DLLDB_ENABLE_LUA=OFF \
    -DLLDB_ENABLE_LIBEDIT=OFF \
    -DLLDB_ENABLE_CURSES=OFF \
    -DLLDB_ENABLE_LZMA=OFF \
    -DLLDB_ENABLE_LIBXML2=ON \
    -DLLDB_ENABLE_PROTOCOL_SERVERS=OFF \
    -DLLDB_ENABLE_FBSDVMCORE=OFF \
    -DLLDB_INCLUDE_TESTS=OFF

  log "Installing lldb"
  cmake --build "$LLDB_BUILD_DIR" --parallel "$JOBS" --target install
}

render_linux_driver_cfg() {
  local triple="$1"
  local cfg_path="$2"
  local add_cxx="$3"
  local cxx_args=""

  if [[ "$add_cxx" == "1" ]]; then
    cxx_args=$'-stdlib=libc++\n-isystem\n<CFGDIR>/../include/c++/v1\n-isystem\n<CFGDIR>/../include/'"${triple}"$'/c++/v1\n'
  fi

  render_template "${TEMPLATE_DIR}/clang-linux-driver.cfg.in" "$cfg_path" \
    "TARGET_TRIPLE=${triple}" \
    "LLVM_MAJOR_VERSION=${LLVM_MAJOR_VERSION}" \
    "CXX_ARGS=${cxx_args}"
}

render_mingw64_driver_cfg() {
  local cfg_path="$1"
  local add_cxx="$2"
  local cxx_args=""
  local mingw_root="<CFGDIR>/../../x86_64-w64-windows-gnu"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    render_template "${TEMPLATE_DIR}/clang-mingw64-native-driver.cfg.in" "$cfg_path" \
      "TARGET_TRIPLE=x86_64-w64-windows-gnu"
    return 0
  fi

  if [[ "$add_cxx" == "1" ]]; then
    cxx_args=$'-stdlib=libc++\n-isystem\n<CFGDIR>/../include/c++/v1\n-isystem\n<CFGDIR>/../include/x86_64-w64-windows-gnu/c++/v1\n'
  fi

  render_template "${TEMPLATE_DIR}/clang-mingw64-driver.cfg.in" "$cfg_path" \
    "TARGET_TRIPLE=x86_64-w64-windows-gnu" \
    "LLVM_MAJOR_VERSION=${LLVM_MAJOR_VERSION}" \
    "MINGW_ROOT=${mingw_root}" \
    "CXX_ARGS=${cxx_args}"
}

create_driver_links_and_cfgs() {
  local bin_dir="${SDK_PREFIX}/bin"
  local triple=""
  local linux_triples=(
    x86_64-unknown-linux-gnu
    aarch64-unknown-linux-gnu
    riscv64-unknown-linux-gnu
    loongarch64-unknown-linux-gnu
  )

  mkdir -p "$bin_dir"

  for triple in "${linux_triples[@]}"; do
    render_linux_driver_cfg "$triple" "${bin_dir}/${triple}-clang-gcc.cfg" 0
    render_linux_driver_cfg "$triple" "${bin_dir}/${triple}-clang-g++.cfg" 1

    if [[ "$TARGET_KIND" == "mingw" ]]; then
      cp -f "${bin_dir}/clang.exe" "${bin_dir}/${triple}-clang-gcc.exe"
      cp -f "${bin_dir}/clang++.exe" "${bin_dir}/${triple}-clang-g++.exe"
    else
      ln -sfn clang "${bin_dir}/${triple}-clang-gcc"
      ln -sfn clang++ "${bin_dir}/${triple}-clang-g++"
      ln -sfn llvm-ar "${bin_dir}/${triple}-ar"
      ln -sfn llvm-nm "${bin_dir}/${triple}-nm"
      ln -sfn llvm-objcopy "${bin_dir}/${triple}-objcopy"
      ln -sfn llvm-ranlib "${bin_dir}/${triple}-ranlib"
      ln -sfn llvm-strip "${bin_dir}/${triple}-strip"
    fi
  done

  render_mingw64_driver_cfg "${bin_dir}/x86_64-w64-windows-gnu-clang-gcc.cfg" 0
  render_mingw64_driver_cfg "${bin_dir}/x86_64-w64-windows-gnu-clang-g++.cfg" 1
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cp -f "${bin_dir}/clang.exe" "${bin_dir}/x86_64-w64-windows-gnu-clang-gcc.exe"
    cp -f "${bin_dir}/clang++.exe" "${bin_dir}/x86_64-w64-windows-gnu-clang-g++.exe"
  else
    ln -sfn clang "${bin_dir}/x86_64-w64-windows-gnu-clang-gcc"
    ln -sfn clang++ "${bin_dir}/x86_64-w64-windows-gnu-clang-g++"
  fi
}

create_mingw64_native_toolchain_file() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  render_template "${TEMPLATE_DIR}/mingw64-native-toolchain.cmake.in" "${SDK_PREFIX}/toolchain.cmake" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}"
}

validate_outputs() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    [[ -x "${SDK_PREFIX}/bin/clang.exe" ]] || die "missing clang.exe"
    [[ -x "${SDK_PREFIX}/bin/clang++.exe" ]] || die "missing clang++.exe"
    [[ -x "${SDK_PREFIX}/bin/lld.exe" ]] || die "missing lld.exe"
    [[ -x "${SDK_PREFIX}/bin/lldb.exe" ]] || die "missing lldb.exe"
    [[ -x "${SDK_PREFIX}/bin/ld.lld.exe" ]] || die "missing ld.lld.exe"
    [[ -x "${SDK_PREFIX}/bin/clang-tidy.exe" ]] || die "missing clang-tidy.exe"
    [[ -e "${SDK_PREFIX}/bin/libclang.dll" ]] || die "missing libclang.dll"
    [[ -e "${SDK_PREFIX}/bin/libclang-cpp.dll" ]] || die "missing libclang-cpp.dll"
    [[ -x "${SDK_PREFIX}/bin/${TARGET_TRIPLE}-clang-gcc.exe" ]] || die "missing host target clang driver"
    [[ ! -e "${SDK_PREFIX}/${TARGET_TRIPLE}" ]] || die "unexpected nested mingw64 sysroot directory"
    [[ -f "${SDK_PREFIX}/include/_mingw.h" ]] || die "missing flattened mingw64 CRT headers"
    [[ -f "${SDK_PREFIX}/lib/crt2.o" ]] || die "missing flattened mingw64 CRT startup objects"
    [[ -f "${SDK_PREFIX}/lib/libmingw32.a" ]] || die "missing flattened mingw64 import libraries"
    [[ -f "${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/lib/windows/libclang_rt.builtins-x86_64.a" ]] \
      || die "missing Windows compiler-rt builtins alias"
    [[ -f "${SDK_PREFIX}/toolchain.cmake" ]] || die "missing mingw64 native CMake toolchain"
  else
    [[ -x "${SDK_PREFIX}/bin/clang" ]] || die "missing clang"
    [[ -x "${SDK_PREFIX}/bin/clang++" ]] || die "missing clang++"
    [[ -x "${SDK_PREFIX}/bin/lld" ]] || die "missing lld"
    [[ -x "${SDK_PREFIX}/bin/lldb" ]] || die "missing lldb"
    [[ -x "${SDK_PREFIX}/bin/ld.lld" ]] || die "missing ld.lld"
    [[ -x "${SDK_PREFIX}/bin/clang-tidy" ]] || die "missing clang-tidy"
    [[ -e "${SDK_PREFIX}/lib/libclang.so" ]] || die "missing libclang.so"
    [[ -e "${SDK_PREFIX}/lib/libclang-cpp.so" ]] || die "missing libclang-cpp.so"
    [[ -f "${SDK_PREFIX}/bin/${TARGET_TRIPLE}-clang-gcc.cfg" ]] || die "missing host target clang cfg"
  fi
  [[ -f "${SDK_PREFIX}/bin/${TARGET_TRIPLE}-clang-gcc.cfg" ]] || die "missing host target clang cfg"
  [[ -f "${SDK_PREFIX}/bin/x86_64-w64-windows-gnu-clang-g++.cfg" ]] || die "missing mingw64 clang++ cfg"
  [[ -d "${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/include" ]] || die "missing clang resource headers"
  [[ -d "${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/lib/x86_64-w64-windows-gnu" ]] || die "missing mingw64 compiler-rt resource libraries"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_MAJOR_VERSION="${LLVM_MAJOR_VERSION:-${LLVM_VERSION%%.*}}"
BOOTSTRAP_LLVM_VERSION="${BOOTSTRAP_LLVM_VERSION:-18.1.8}"
PREBUILT_LLVM_ROOT="${PREBUILT_LLVM_ROOT:-/opt/llvm-${BOOTSTRAP_LLVM_VERSION}}"
LLVMSDK_PREFIX="${LLVMSDK_PREFIX:-/work/llvmsdk}"
NATIVE_LLVMSDK_PREFIX="${NATIVE_LLVMSDK_PREFIX:-/work/native-llvmsdk}"
NATIVE_STAGE0_PREFIX="${NATIVE_STAGE0_PREFIX:-/work/native-stage0}"
MINGW_SYSROOT_PREFIX="${MINGW_SYSROOT_PREFIX:-/work/mingw64-sysroot}"
LIBCXX_INPUT_ROOT="${LIBCXX_INPUT_ROOT:-/work/libcxx}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/clang-${LLVM_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
LLVM_ARCHIVE_NAME="${LLVM_ARCHIVE_NAME:-llvm-project-${LLVM_VERSION}.src.tar.xz}"
LLVM_ARCHIVE_URL="${LLVM_ARCHIVE_URL:-https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}}"
LLVM_TARGETS="${LLVM_TARGETS:-all}"
LLVM_EXPERIMENTAL_TARGETS="${LLVM_EXPERIMENTAL_TARGETS:-all}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%d)}"
LLVM_VC_REPOSITORY="${LLVM_VC_REPOSITORY:-https://github.com/zarraxx/develop_suit}"
case "$TARGET_KIND" in
  linux)
    CMAKE_SYSTEM_NAME="Linux"
    CMAKE_SYSTEM_PROCESSOR="$ARCH"
    TARGET_ROOT="${TARGET_ROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}}"
    CMAKE_STANDARD_LIBRARY_ARGS=()
    CMAKE_RPATH_ARGS=(
      "-DCMAKE_INSTALL_RPATH=\$ORIGIN/../lib"
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    )
    ;;
  mingw)
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-${MINGW_SYSROOT_PREFIX}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CMAKE_STANDARD_LIBRARY_ARGS=(
      "-DCMAKE_CXX_STANDARD_LIBRARIES=${SDK_PREFIX}/lib/${TARGET_TRIPLE}/libc++.dll.a ${SDK_PREFIX}/lib/${TARGET_TRIPLE}/libc++abi.a ${SDK_PREFIX}/lib/${TARGET_TRIPLE}/libunwind.dll.a -lole32"
    )
    CMAKE_RPATH_ARGS=()
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
RESOURCE_DIR="${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}"
RESOURCE_LIB_DIR="${RESOURCE_DIR}/lib/${TARGET_TRIPLE}"
RUNTIME_LIB_DIR="${SDK_PREFIX}/lib/${TARGET_TRIPLE}"
NATIVE_TOOL_DIR="${BUILD_DIR}/native-tools"
NATIVE_CLANG_TOOLS_BUILD_DIR="${BUILD_DIR}/native-clang-tools-build"
NATIVE_LLDB_TOOLS_BUILD_DIR="${BUILD_DIR}/native-lldb-tools-build"
CLANG_BUILD_DIR="${BUILD_DIR}/clang-final-build"
LLD_BUILD_DIR="${BUILD_DIR}/lld-final-build"
LLDB_BUILD_DIR="${BUILD_DIR}/lldb-final-build"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$SYSROOT" ]] || die "missing host sysroot: ${SYSROOT}"
[[ -f "${LLVMSDK_PREFIX}/lib/cmake/llvm/LLVMConfig.cmake" ]] || die "missing target LLVMConfig.cmake"
[[ -f "${NATIVE_LLVMSDK_PREFIX}/lib/cmake/llvm/LLVMConfig.cmake" ]] || die "missing native LLVMConfig.cmake"
[[ -x "${NATIVE_LLVMSDK_PREFIX}/bin/llvm-tblgen" ]] || die "missing native llvm-tblgen"
[[ -x "${NATIVE_STAGE0_PREFIX}/bin/clang" ]] || die "missing native stage0 clang"
[[ -x "${NATIVE_STAGE0_PREFIX}/bin/clang++" ]] || die "missing native stage0 clang++"
[[ -d "$LIBCXX_INPUT_ROOT" ]] || die "missing libcxx input root: ${LIBCXX_INPUT_ROOT}"

require_command curl
require_command tar
require_command cmake
require_command ninja
require_command patch

download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
LLVM_SOURCE_ROOT="$(extract_llvm_source)"
apply_source_patches

set_stage_llvm_policy_args

assemble_sdk_prefix
copy_host_runtime_shared_libraries_to_lib
make_native_tool_dir

TARGET_C_FLAGS="--target=${TARGET_TRIPLE} --sysroot=${SYSROOT} -resource-dir=${RESOURCE_DIR}"
TARGET_CXX_FLAGS="${TARGET_C_FLAGS} -stdlib=libc++ -isystem ${SDK_PREFIX}/include/c++/v1 -isystem ${SDK_PREFIX}/include/${TARGET_TRIPLE}/c++/v1"
if [[ "$TARGET_KIND" == "linux" ]]; then
  TARGET_C_FLAGS+=" -pthread"
  TARGET_CXX_FLAGS+=" -pthread"
  TARGET_LINK_FLAGS="-fuse-ld=lld -B${RESOURCE_LIB_DIR} -L${SDK_PREFIX}/lib -L${RESOURCE_LIB_DIR} -L${RUNTIME_LIB_DIR} --rtlib=compiler-rt --unwindlib=libunwind -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${RESOURCE_LIB_DIR} -Wl,-rpath-link,${RUNTIME_LIB_DIR} -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64 -pthread"
else
  TARGET_C_FLAGS+=" -D__USE_MINGW_ANSI_STDIO=1"
  TARGET_CXX_FLAGS+=" -D__USE_MINGW_ANSI_STDIO=1"
  TARGET_C_FLAGS+=" -isystem ${SYSROOT}/usr/${TARGET_TRIPLE}/include"
  TARGET_CXX_FLAGS+=" -isystem ${SYSROOT}/usr/${TARGET_TRIPLE}/include"
  TARGET_LINK_FLAGS="-fuse-ld=lld -nostdlib++ -B${TARGET_ROOT}/bin -B${RESOURCE_LIB_DIR} -L${SYSROOT}/usr/${TARGET_TRIPLE}/lib -L${SYSROOT}/lib -L${TARGET_ROOT}/lib -L${RESOURCE_LIB_DIR} -L${RUNTIME_LIB_DIR} --rtlib=compiler-rt --unwindlib=libunwind"
fi

export LD_LIBRARY_PATH="${NATIVE_STAGE0_PREFIX}/lib:${NATIVE_LLVMSDK_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

build_clang_and_tools
build_lld
build_lldb
copy_mingw64_sysroot_to_prefix
strip_mingw64_crt_debug_sections

if [[ -x "${SDK_PREFIX}/bin/clang" && ! -e "${SDK_PREFIX}/bin/clang++" ]]; then
  ln -s clang "${SDK_PREFIX}/bin/clang++"
fi
if [[ -x "${SDK_PREFIX}/bin/lld" && ! -e "${SDK_PREFIX}/bin/ld.lld" ]]; then
  ln -s lld "${SDK_PREFIX}/bin/ld.lld"
fi

create_driver_links_and_cfgs
create_mingw64_native_toolchain_file

patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"

render_template "${TEMPLATE_DIR}/README.clang.in" "${SDK_PREFIX}/README.clang" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}"

validate_outputs

log "clang package ready: ${SDK_PREFIX}"
