#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/var.sh"
source "${SHELL_TOOLS_DIR}/tools.sh"

UNIT_NAME="$(basename $ROOT_DIR)"
UNIT_VERSION="18.1.8"

TARGET=""
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*)
      TARGET="${1#*=}"
      ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    target=*|arch=*)
      TARGET="${1#*=}"
      ;;
    --unit-version=*)
      UNIT_VERSION="${1#*=}"
      ;;
    --unit-version)
      shift
      [[ $# -gt 0 ]] || die "--unit-version requires a value"
      UNIT_VERSION="$1"
      ;;
    --image=*|--linux-image=*|--mingw-image=*)
      BUILD_IMAGE="${1#*=}"
      ;;
    --image|--linux-image|--mingw-image)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
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
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
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
    --deps-only)
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "LLVM dependency target"

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="${UNIT_NAME}-${UNIT_VERSION}-${PACKAGE_TRIPLE}"
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

[[ -f "${MOUNT_ROOT}/container_build.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_build.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning ${UNIT_NAME} target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- ${UNIT_NAME} build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
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
  -e ARCH="$ARCH" \
  -e TARGET_KIND="$TARGET_KIND" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e UNIT_VERSION="$UNIT_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_build.sh

make_host_writable "$PACKAGE_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- ${UNIT_NAME} archive ready: ${ARCHIVE_PATH}"
