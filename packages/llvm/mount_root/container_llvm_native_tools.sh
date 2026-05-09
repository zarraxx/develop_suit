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

copy_native_tool() {
  local build_bin_dir="$1"
  local tool="$2"

  [[ -x "${build_bin_dir}/${tool}" ]] || die "missing native tool: ${build_bin_dir}/${tool}"
  cp -a "${build_bin_dir}/${tool}" "${SDK_PREFIX}/bin/"
}

LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_MAJOR_VERSION="${LLVM_MAJOR_VERSION:-${LLVM_VERSION%%.*}}"
BOOTSTRAP_LLVM_VERSION="${BOOTSTRAP_LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/native_llvmsdk-${LLVM_VERSION}-x86_64-unknown-linux-gnu}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PREBUILT_LLVM_ROOT="${PREBUILT_LLVM_ROOT:-/opt/llvm-${BOOTSTRAP_LLVM_VERSION}}"
LLVM_ARCHIVE_NAME="${LLVM_ARCHIVE_NAME:-llvm-project-${LLVM_VERSION}.src.tar.xz}"
LLVM_ARCHIVE_URL="${LLVM_ARCHIVE_URL:-https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${LLVM_ARCHIVE_NAME}}"
LLVM_TARGETS="${LLVM_TARGETS:-all}"
LLVM_EXPERIMENTAL_TARGETS="${LLVM_EXPERIMENTAL_TARGETS:-all}"
NATIVE_TOOLS_BUILD_DIR="${BUILD_DIR}/llvm-native-tools-build"

[[ -d "$PREBUILT_LLVM_ROOT" ]] || die "missing prebuilt LLVM root: ${PREBUILT_LLVM_ROOT}"
[[ -x "${PREBUILT_LLVM_ROOT}/bin/clang" ]] || die "missing prebuilt clang: ${PREBUILT_LLVM_ROOT}/bin/clang"
[[ -x "${PREBUILT_LLVM_ROOT}/bin/clang++" ]] || die "missing prebuilt clang++: ${PREBUILT_LLVM_ROOT}/bin/clang++"

require_command curl
require_command tar
require_command cmake
require_command ninja

download_archive "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE_NAME"
LLVM_SOURCE_ROOT="$(extract_llvm_source)"

rm -rf "$NATIVE_TOOLS_BUILD_DIR"
mkdir -p "$NATIVE_TOOLS_BUILD_DIR" "${SDK_PREFIX}/bin"

log "Configuring native LLVM tools"
log "Target LLVM version: ${LLVM_VERSION}"
log "Prebuilt LLVM root: ${PREBUILT_LLVM_ROOT}"
log "LLVM targets: ${LLVM_TARGETS}"
log "LLVM experimental targets: ${LLVM_EXPERIMENTAL_TARGETS}"

cmake -S "${LLVM_SOURCE_ROOT}/llvm" -B "$NATIVE_TOOLS_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${PREBUILT_LLVM_ROOT}/bin/clang" \
  -DCMAKE_CXX_COMPILER="${PREBUILT_LLVM_ROOT}/bin/clang++" \
  "-DLLVM_TARGETS_TO_BUILD=${LLVM_TARGETS}" \
  "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=${LLVM_EXPERIMENTAL_TARGETS}" \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_BENCHMARKS=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_FFI=OFF

log "Building native LLVM tools"
cmake --build "$NATIVE_TOOLS_BUILD_DIR" --parallel "$JOBS" --target \
  llvm-tblgen \
  llvm-config \
  llvm-nm \
  llvm-readobj

for tool in \
  llvm-tblgen \
  llvm-config \
  llvm-nm \
  llvm-readobj
do
  copy_native_tool "${NATIVE_TOOLS_BUILD_DIR}/bin" "$tool"
done

render_template "${TEMPLATE_DIR}/README.native_llvmsdk.in" "${SDK_PREFIX}/README.native_llvmsdk" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "BOOTSTRAP_LLVM_VERSION=${BOOTSTRAP_LLVM_VERSION}" \
  "LLVM_TARGETS=${LLVM_TARGETS}" \
  "LLVM_EXPERIMENTAL_TARGETS=${LLVM_EXPERIMENTAL_TARGETS}"

log "Native LLVM tools ready: ${SDK_PREFIX}"
