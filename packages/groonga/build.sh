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
  ./packages/groonga/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>            Groonga package target, see list above
  --arch=<target>              Alias for --target
  --xxhash-version=<ver>       xxHash version (default: 0.8.3)
  --msgpackc-version=<ver>     msgpack-c version (default: 6.1.0)
  --groonga-version=<ver>      Groonga version (default: 16.0.5)
  --llvm-version=<ver>         Bootstrap LLVM toolchain version (default: 18.1.8)
  --image=<image>              Build image for every target
                               (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                   Parallel build jobs inside container (default: 4)
  --package-name=<name>        Override the top-level directory and tarball stem
  --pull                       Pull the selected build image before building
  --clean                      Remove this target's build and output directories first
  -h, --help                   Show this help

Outputs:
  packages/groonga/build/dist/groonga-<groonga-version>-<triple>.tar.xz
EOF
}

TARGET=""
XXHASH_VERSION="0.8.3"
MSGPACKC_VERSION="6.1.0"
GROONGA_VERSION="16.0.5"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
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
    --xxhash-version=*) XXHASH_VERSION="${1#*=}" ;;
    --xxhash-version)
      shift
      [[ $# -gt 0 ]] || die "--xxhash-version requires a value"
      XXHASH_VERSION="$1"
      ;;
    --msgpackc-version=*|--msgpack-c-version=*) MSGPACKC_VERSION="${1#*=}" ;;
    --msgpackc-version|--msgpack-c-version)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      MSGPACKC_VERSION="$1"
      ;;
    --groonga-version=*) GROONGA_VERSION="${1#*=}" ;;
    --groonga-version)
      shift
      [[ $# -gt 0 ]] || die "--groonga-version requires a value"
      GROONGA_VERSION="$1"
      ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --image=*|--linux-image=*|--mingw-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image|--mingw-image)
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
resolve_target "$TARGET" "Groonga target"

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="groonga-${GROONGA_VERSION}-${PACKAGE_TRIPLE}"
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

case "$TARGET_KIND" in
  linux)
    if [[ "$ARCH" == "x86_64" ]]; then
      CONTAINER_SCRIPT="container_linux_native.sh"
    else
      CONTAINER_SCRIPT="container_linux_cross.sh"
    fi
    ;;
  mingw)
    CONTAINER_SCRIPT="container_mingw64.sh"
    ;;
  *)
    die "unsupported target kind: ${TARGET_KIND}"
    ;;
esac

[[ -f "${MOUNT_ROOT}/${CONTAINER_SCRIPT}" ]] || die "missing container script: ${MOUNT_ROOT}/${CONTAINER_SCRIPT}"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning Groonga target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

mkdir -p "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- Groonga build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- xxHash version: ${XXHASH_VERSION}"
echo "-- msgpack-c version: ${MSGPACKC_VERSION}"
echo "-- groonga version: ${GROONGA_VERSION}"
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
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e XXHASH_VERSION="$XXHASH_VERSION" \
  -e MSGPACKC_VERSION="$MSGPACKC_VERSION" \
  -e GROONGA_VERSION="$GROONGA_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash "/work/mount_root/${CONTAINER_SCRIPT}"

make_host_writable "$PACKAGE_ROOT"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- Groonga archive ready: ${ARCHIVE_PATH}"
