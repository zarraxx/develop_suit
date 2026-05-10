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

  if [[ ! -f "${extract_dir}/clang/CMakeLists.txt" || ! -f "${extract_dir}/lld/CMakeLists.txt" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "${CACHE_DIR}/${LLVM_ARCHIVE_NAME}" -C "$extract_dir" --strip-components=1
  fi

  [[ -f "${extract_dir}/clang/CMakeLists.txt" ]] || die "invalid clang source tree: ${extract_dir}"
  [[ -f "${extract_dir}/lld/CMakeLists.txt" ]] || die "invalid lld source tree: ${extract_dir}"
  printf '%s\n' "$extract_dir"
}

copy_llvmsdk_shared_libraries() {
  mkdir -p "${SDK_PREFIX}/lib"

  find "${HOST_LLVMSDK_PREFIX}/lib" -maxdepth 1 -type f \
    \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -a {} "${SDK_PREFIX}/lib/" \;

  find "${HOST_LLVMSDK_PREFIX}/lib" -maxdepth 1 -type l \
    \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -a {} "${SDK_PREFIX}/lib/" \;
}

ensure_driver_symlinks() {
  mkdir -p "${SDK_PREFIX}/bin"

  if [[ -x "${SDK_PREFIX}/bin/clang" && ! -e "${SDK_PREFIX}/bin/clang++" ]]; then
    ln -s clang "${SDK_PREFIX}/bin/clang++"
  fi
  if [[ -x "${SDK_PREFIX}/bin/lld" && ! -e "${SDK_PREFIX}/bin/ld.lld" ]]; then
    ln -s lld "${SDK_PREFIX}/bin/ld.lld"
  fi
}

validate_stage0() {
  [[ -x "${SDK_PREFIX}/bin/clang" ]] || die "missing installed clang"
  [[ -x "${SDK_PREFIX}/bin/clang++" ]] || die "missing installed clang++"
  [[ -x "${SDK_PREFIX}/bin/lld" ]] || die "missing installed lld"
  [[ -x "${SDK_PREFIX}/bin/ld.lld" ]] || die "missing installed ld.lld"
  [[ -d "${SDK_PREFIX}/lib/clang/${LLVM_MAJOR_VERSION}/include" ]] || die "missing clang resource headers"

  LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${HOST_LLVMSDK_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${SDK_PREFIX}/bin/clang" --version >/dev/null
  LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${HOST_LLVMSDK_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${SDK_PREFIX}/bin/ld.lld" --version >/dev/null
}

LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_MAJOR_VERSION="${LLVM_MAJOR_VERSION:-${LLVM_VERSION%%.*}}"
BOOTSTRAP_LLVM_VERSION="${BOOTSTRAP_LLVM_VERSION:-18.1.8}"
HOST_TRIPLE="${HOST_TRIPLE:-x86_64-unknown-linux-gnu}"
HOST_LLVMSDK_PREFIX="${HOST_LLVMSDK_PREFIX:-/work/llvmsdk}"
PREBUILT_LLVM_ROOT="${PREBUILT_LLVM_ROOT:-/opt/llvm-${BOOTSTRAP_LLVM_VERSION}}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/native-clang-stage0-${LLVM_VERSION}-${HOST_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
LLVM_ARCHIVE_NAME="${LLVM_ARCHIVE_NAME:-llvm-project-${LLVM_VERSION}.src.tar.xz}"
LLVM_ARCHIVE_URL="${LLVM_ARCHIVE_URL:-https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}}"
STAGE0_TARGETS="${STAGE0_TARGETS:-X86;AArch64;RISCV;LoongArch}"
CLANG_BUILD_DIR="${BUILD_DIR}/native-stage0-clang-build"
LLD_BUILD_DIR="${BUILD_DIR}/native-stage0-lld-build"

[[ -d "$HOST_LLVMSDK_PREFIX" ]] || die "missing host llvmsdk prefix: ${HOST_LLVMSDK_PREFIX}"
[[ -f "${HOST_LLVMSDK_PREFIX}/lib/cmake/llvm/LLVMConfig.cmake" ]] || die "missing host LLVMConfig.cmake"
[[ -x "${HOST_LLVMSDK_PREFIX}/bin/llvm-config" ]] || die "missing host llvm-config"
[[ -x "${HOST_LLVMSDK_PREFIX}/bin/llvm-tblgen" ]] || die "missing host llvm-tblgen"
[[ -d "$PREBUILT_LLVM_ROOT" ]] || die "missing prebuilt LLVM root: ${PREBUILT_LLVM_ROOT}"
[[ -x "${PREBUILT_LLVM_ROOT}/bin/clang" ]] || die "missing prebuilt clang: ${PREBUILT_LLVM_ROOT}/bin/clang"
[[ -x "${PREBUILT_LLVM_ROOT}/bin/clang++" ]] || die "missing prebuilt clang++: ${PREBUILT_LLVM_ROOT}/bin/clang++"

require_command curl
require_command tar
require_command cmake
require_command ninja

download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
LLVM_SOURCE_ROOT="$(extract_llvm_source)"

export LD_LIBRARY_PATH="${HOST_LLVMSDK_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

rm -rf "$CLANG_BUILD_DIR" "$LLD_BUILD_DIR"
mkdir -p "$CLANG_BUILD_DIR" "$LLD_BUILD_DIR" "$SDK_PREFIX"

log "Configuring native stage0 clang"
cmake -S "${LLVM_SOURCE_ROOT}/clang" -B "$CLANG_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
  -DCMAKE_C_COMPILER="${PREBUILT_LLVM_ROOT}/bin/clang" \
  -DCMAKE_CXX_COMPILER="${PREBUILT_LLVM_ROOT}/bin/clang++" \
  "-DCMAKE_PREFIX_PATH=${HOST_LLVMSDK_PREFIX}" \
  "-DCMAKE_INSTALL_RPATH=\$ORIGIN/../lib" \
  "-DLLVM_DIR=${HOST_LLVMSDK_PREFIX}/lib/cmake/llvm" \
  "-DLLVM_TABLEGEN=${HOST_LLVMSDK_PREFIX}/bin/llvm-tblgen" \
  "-DLLVM_CONFIG_PATH=${HOST_LLVMSDK_PREFIX}/bin/llvm-config" \
  "-DLLVM_TARGETS_TO_BUILD=${STAGE0_TARGETS}" \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DCLANG_LINK_CLANG_DYLIB=ON \
  -DCLANG_BUILD_TOOLS=ON \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DCLANG_BUILD_EXAMPLES=OFF \
  -DCLANG_ENABLE_ARCMT=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_BOOTSTRAP=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF

log "Installing native stage0 clang"
cmake --build "$CLANG_BUILD_DIR" --parallel "$JOBS" --target install

log "Configuring native stage0 lld"
cmake -S "${LLVM_SOURCE_ROOT}/lld" -B "$LLD_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
  -DCMAKE_C_COMPILER="${PREBUILT_LLVM_ROOT}/bin/clang" \
  -DCMAKE_CXX_COMPILER="${PREBUILT_LLVM_ROOT}/bin/clang++" \
  "-DCMAKE_PREFIX_PATH=${HOST_LLVMSDK_PREFIX}" \
  "-DCMAKE_INSTALL_RPATH=\$ORIGIN/../lib" \
  "-DLLVM_DIR=${HOST_LLVMSDK_PREFIX}/lib/cmake/llvm" \
  "-DLLVM_TABLEGEN=${HOST_LLVMSDK_PREFIX}/bin/llvm-tblgen" \
  "-DLLVM_CONFIG_PATH=${HOST_LLVMSDK_PREFIX}/bin/llvm-config" \
  "-DLLVM_TARGETS_TO_BUILD=${STAGE0_TARGETS}" \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLD_BUILD_TOOLS=ON \
  -DLLD_INCLUDE_TESTS=OFF \
  -DLLD_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF

log "Installing native stage0 lld"
cmake --build "$LLD_BUILD_DIR" --parallel "$JOBS" --target install

copy_llvmsdk_shared_libraries
ensure_driver_symlinks

render_template "${TEMPLATE_DIR}/README.native-clang-stage0.in" "${SDK_PREFIX}/README.native-clang-stage0" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "BOOTSTRAP_LLVM_VERSION=${BOOTSTRAP_LLVM_VERSION}" \
  "HOST_TRIPLE=${HOST_TRIPLE}" \
  "STAGE0_TARGETS=${STAGE0_TARGETS}"

validate_stage0

log "Native clang stage0 ready: ${SDK_PREFIX}"
