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
  ./packages/llvm/build_native_tools.sh [options]

Options:
  --llvm-version=<ver>    LLVM version for the native tools (default: 18.1.8)
  --bootstrap-llvm-version=<ver>
                          LLVM version already installed in the build image
                          and used to build the native tools (default: 18.1.8)
  --image=<image>         Build image
                          (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>              Parallel build jobs inside container (default: 4)
  --package-name=<name>   Override the top-level directory and tarball stem
  --pull                  Pull the selected build image before building
  --clean                 Remove native tools build and output directories first
  -h, --help              Show this help

Outputs:
  packages/llvm/build/dist/native_llvmsdk-<version>-x86_64-unknown-linux-gnu.tar.xz
EOF
}

LLVM_VERSION="18.1.8"
BOOTSTRAP_LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --llvm-version=*)
      LLVM_VERSION="${1#*=}"
      ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
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
  PACKAGE_NAME="native_llvmsdk-${LLVM_VERSION}-x86_64-unknown-linux-gnu"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
SDK_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${SDK_ROOT}/work/native_llvmsdk-${LLVM_VERSION}"
OUT_BASE="${SDK_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${SDK_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_llvm_native_tools.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_llvm_native_tools.sh"

make_host_writable "$SDK_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning native LLVM tools build"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- native LLVM tools build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- LLVM version: ${LLVM_VERSION}"
echo "-- bootstrap LLVM version: ${BOOTSTRAP_LLVM_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

docker run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  --workdir /work \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e BOOTSTRAP_LLVM_VERSION="$BOOTSTRAP_LLVM_VERSION" \
  -e PREBUILT_LLVM_ROOT="/opt/llvm-${BOOTSTRAP_LLVM_VERSION}" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_llvm_native_tools.sh

make_host_writable "$SDK_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- native LLVM tools archive ready: ${ARCHIVE_PATH}"
