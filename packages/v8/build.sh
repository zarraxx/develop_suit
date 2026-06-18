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
  ./packages/v8/build.sh --target=<target> [options]

Targets:
  x86_64, x86_64-unknown-linux-gnu
  loongarch64, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>             V8 target, see list above
  --arch=<target>               Alias for --target
  --v8-version=<ver>            v8-cmake tag/V8 version (default: 11.6.189.4)
  --llvm-version=<ver>          Bootstrap LLVM toolchain version (default: 18.1.8)
  --v8-archive=<tar>            Use a local v8-cmake source archive
  --image=<image>               Build image
                                (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                    Parallel build jobs inside container (default: 4)
  --package-name=<name>         Override the top-level directory and tarball stem
  --pull                        Pull the selected build image before building
  --clean                       Remove this target's build and output directories first
  -h, --help                    Show this help

Outputs:
  packages/v8/build/dist/v8-<version>-<triple>.tar.xz
EOF
}

TARGET=""
V8_VERSION="11.6.189.4"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
V8_ARCHIVE=""
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    target=*|arch=*) TARGET="${1#*=}" ;;
    --v8-version=*) V8_VERSION="${1#*=}" ;;
    --v8-version)
      shift
      [[ $# -gt 0 ]] || die "--v8-version requires a value"
      V8_VERSION="$1"
      ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --v8-archive=*) V8_ARCHIVE="${1#*=}" ;;
    --v8-archive)
      shift
      [[ $# -gt 0 ]] || die "--v8-archive requires a value"
      V8_ARCHIVE="$1"
      ;;
    --image=*|--linux-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      BUILD_IMAGE="$1"
      ;;
    --jobs=*) JOBS="${1#*=}" ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --package-name=*) PACKAGE_NAME="${1#*=}" ;;
    --package-name)
      shift
      [[ $# -gt 0 ]] || die "--package-name requires a value"
      PACKAGE_NAME="$1"
      ;;
    --pull) PULL=1 ;;
    --clean) CLEAN=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "V8 target"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:loongarch64|mingw:x86_64) ;;
  *) die "V8 package currently supports x86_64/loongarch64 Linux and x86_64 MinGW" ;;
esac

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="v8-${V8_VERSION}-${PACKAGE_TRIPLE}"
fi

if [[ -n "$V8_ARCHIVE" ]]; then
  [[ -f "$V8_ARCHIVE" ]] || die "v8-cmake source archive not found: ${V8_ARCHIVE}"
  V8_ARCHIVE="$(cd "$(dirname "$V8_ARCHIVE")" && pwd)/$(basename "$V8_ARCHIVE")"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_v8.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_v8.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning V8 target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- V8 build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- v8-cmake version: ${V8_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$V8_ARCHIVE" ]]; then
  echo "-- source archive: ${V8_ARCHIVE}"
fi

docker_args=(
  run --rm
  --platform linux/amd64
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro"
  -v "${MOUNT_ROOT}:/work/mount_root:ro"
  -v "${CACHE_DIR}:/work/cache"
  -v "${BUILD_DIR}:/work/build"
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}"
  --workdir /work
  -e "ARCH=${ARCH}"
  -e "TARGET_KIND=${TARGET_KIND}"
  -e "TARGET_TRIPLE=${TARGET_TRIPLE}"
  -e "LLVM_VERSION=${LLVM_VERSION}"
  -e "V8_VERSION=${V8_VERSION}"
  -e "JOBS=${JOBS}"
  -e "SDK_PREFIX=/opt/${PACKAGE_NAME}"
)
if [[ -n "$V8_ARCHIVE" ]]; then
  docker_args+=(
    -v "${V8_ARCHIVE}:/work/input/v8-cmake-${V8_VERSION}.tar.gz:ro"
    -e "V8_ARCHIVE=/work/input/v8-cmake-${V8_VERSION}.tar.gz"
  )
fi
docker_args+=(
  "$BUILD_IMAGE"
  /bin/bash /work/mount_root/container_v8.sh
)

docker "${docker_args[@]}"

make_host_writable "$PACKAGE_ROOT"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- V8 archive ready: ${ARCHIVE_PATH}"
