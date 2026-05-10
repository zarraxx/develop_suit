#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/var.sh"
source "${SHELL_TOOLS_DIR}/tools.sh"

usage() {
  cat <<'EOF'
Usage:
  ./packages/clang/build_native_stage0.sh [options]

Options:
  --llvm-version=<ver>       LLVM/clang version (default: 18.1.8)
  --bootstrap-llvm-version=<ver>
                             LLVM version already installed in the build image
                             and used as the C/C++ compiler (default: 18.1.8)
  --llvmsdk-archive=<tar>    Same-version x86_64 Linux llvmsdk archive
  --llvmsdk-dir=<dir>        Already extracted same-version x86_64 Linux llvmsdk
  --image=<image>            Build image
                             (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                 Parallel build jobs inside container (default: 4)
  --package-name=<name>      Override the top-level directory and tarball stem
  --pull                     Pull the selected build image before building
  --clean                    Remove native stage0 build and output directories first
  -h, --help                 Show this help

Outputs:
  packages/clang/build/dist/native-clang-stage0-<version>-x86_64-unknown-linux-gnu.tar.xz
EOF
}

find_default_llvmsdk_archive() {
  local archive_name="llvmsdk-${LLVM_VERSION}-${HOST_TRIPLE}.tar.xz"
  local archive_path="${PROJECT_ROOT}/packages/llvm/build/dist/${archive_name}"

  [[ -f "$archive_path" ]] || return 1
  printf '%s\n' "$archive_path"
}

extract_llvmsdk_archive() {
  local archive_path="$1"
  local tmp_extract="${BUILD_DIR}.llvmsdk-extract"
  local extracted_dir=""
  local package_dir="llvmsdk-${LLVM_VERSION}-${HOST_TRIPLE}"

  [[ -f "$archive_path" ]] || die "llvmsdk archive not found: ${archive_path}"

  echo "-- extracting host llvmsdk archive: ${archive_path}"
  rm -rf "$tmp_extract" "$LLVMSDK_INPUT_DIR"
  mkdir -p "$tmp_extract" "$LLVMSDK_INPUT_DIR"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${package_dir}" ]]; then
    extracted_dir="${tmp_extract}/${package_dir}"
  elif [[ -f "${tmp_extract}/lib/cmake/llvm/LLVMConfig.cmake" ]]; then
    extracted_dir="$tmp_extract"
  else
    die "could not find llvmsdk prefix in archive: ${archive_path}"
  fi

  cp -a "${extracted_dir}/." "$LLVMSDK_INPUT_DIR/"
  rm -rf "$tmp_extract"
}

validate_llvmsdk_dir() {
  local llvmsdk_dir="$1"

  [[ -d "$llvmsdk_dir" ]] || die "llvmsdk directory not found: ${llvmsdk_dir}"
  [[ -f "${llvmsdk_dir}/lib/cmake/llvm/LLVMConfig.cmake" ]] || die "missing LLVMConfig.cmake in llvmsdk: ${llvmsdk_dir}"
  [[ -x "${llvmsdk_dir}/bin/llvm-config" ]] || die "missing llvm-config in llvmsdk: ${llvmsdk_dir}"
  [[ -x "${llvmsdk_dir}/bin/llvm-tblgen" ]] || die "missing llvm-tblgen in llvmsdk: ${llvmsdk_dir}"
  [[ -d "${llvmsdk_dir}/include/llvm" ]] || die "missing LLVM headers in llvmsdk: ${llvmsdk_dir}"
  [[ -d "${llvmsdk_dir}/lib" ]] || die "missing LLVM libraries in llvmsdk: ${llvmsdk_dir}"
}

LLVM_VERSION="18.1.8"
BOOTSTRAP_LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
LLVMSDK_ARCHIVE=""
LLVMSDK_DIR=""
PULL=0
CLEAN=0
HOST_TRIPLE="x86_64-unknown-linux-gnu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --llvm-version=*|--unit-version=*)
      LLVM_VERSION="${1#*=}"
      ;;
    --llvm-version|--unit-version)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      LLVM_VERSION="$1"
      ;;
    --bootstrap-llvm-version=*)
      BOOTSTRAP_LLVM_VERSION="${1#*=}"
      ;;
    --bootstrap-llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--bootstrap-llvm-version requires a value"
      BOOTSTRAP_LLVM_VERSION="$1"
      ;;
    --llvmsdk-archive=*)
      LLVMSDK_ARCHIVE="${1#*=}"
      ;;
    --llvmsdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-archive requires a value"
      LLVMSDK_ARCHIVE="$1"
      ;;
    --llvmsdk-dir=*)
      LLVMSDK_DIR="${1#*=}"
      ;;
    --llvmsdk-dir)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-dir requires a value"
      LLVMSDK_DIR="$1"
      ;;
    --image=*)
      BUILD_IMAGE="${1#*=}"
      ;;
    --image)
      shift
      [[ $# -gt 0 ]] || die "--image requires a value"
      BUILD_IMAGE="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --package-name=*)
      PACKAGE_NAME="${1#*=}"
      ;;
    --package-name)
      shift
      [[ $# -gt 0 ]] || die "--package-name requires a value"
      PACKAGE_NAME="$1"
      ;;
    --pull)
      PULL=1
      ;;
    --clean)
      CLEAN=1
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

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="native-clang-stage0-${LLVM_VERSION}-${HOST_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/native-clang-stage0-${LLVM_VERSION}"
LLVMSDK_INPUT_DIR="${BUILD_DIR}/llvmsdk-input"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_stage0.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_stage0.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning native clang stage0"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

if [[ -n "$LLVMSDK_ARCHIVE" && -n "$LLVMSDK_DIR" ]]; then
  die "--llvmsdk-archive and --llvmsdk-dir are mutually exclusive"
fi
if [[ -z "$LLVMSDK_ARCHIVE" && -z "$LLVMSDK_DIR" ]]; then
  LLVMSDK_ARCHIVE="$(find_default_llvmsdk_archive)" \
    || die "llvmsdk archive not provided and default archive was not found for ${HOST_TRIPLE}"
fi

if [[ -n "$LLVMSDK_ARCHIVE" ]]; then
  extract_llvmsdk_archive "$LLVMSDK_ARCHIVE"
  validate_llvmsdk_dir "$LLVMSDK_INPUT_DIR"
  LLVMSDK_MOUNT_DIR="$LLVMSDK_INPUT_DIR"
else
  [[ -d "$LLVMSDK_DIR" ]] || die "llvmsdk directory not found: ${LLVMSDK_DIR}"
  LLVMSDK_MOUNT_DIR="$(cd "$LLVMSDK_DIR" && pwd)"
  validate_llvmsdk_dir "$LLVMSDK_MOUNT_DIR"
fi

echo "-- native clang stage0 build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- LLVM version: ${LLVM_VERSION}"
echo "-- bootstrap LLVM version: ${BOOTSTRAP_LLVM_VERSION}"
echo "-- host triple: ${HOST_TRIPLE}"
echo "-- llvmsdk: ${LLVMSDK_MOUNT_DIR}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

docker run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  -v "${LLVMSDK_MOUNT_DIR}:/work/llvmsdk:ro" \
  --workdir /work \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e BOOTSTRAP_LLVM_VERSION="$BOOTSTRAP_LLVM_VERSION" \
  -e PREBUILT_LLVM_ROOT="/opt/llvm-${BOOTSTRAP_LLVM_VERSION}" \
  -e HOST_TRIPLE="$HOST_TRIPLE" \
  -e HOST_LLVMSDK_PREFIX="/work/llvmsdk" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_stage0.sh

make_host_writable "$PACKAGE_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- native clang stage0 archive ready: ${ARCHIVE_PATH}"
