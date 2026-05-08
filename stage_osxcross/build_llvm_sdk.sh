#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage_osxcross/build_llvm_sdk.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>       SDK target, see list above
  --arch=<target>         Alias for --target
  --llvm-version=<ver>    LLVM version (default: 18.1.8)
  --linux-image=<image>   Build image for Linux SDK targets
                          (default: ghcr.io/zarraxx/develop_suit:llvm-18.1.8)
  --mingw-image=<image>   Build image for the Windows GNU SDK target
                          (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>              Parallel build jobs inside container (default: 4)
  --package-name=<name>   Override the top-level directory and tarball stem
  --dependency-package-name=<name>
                          Override dependency tarball top-level directory and stem
  --pull                  Pull the selected build image before building
  --clean                 Remove this target's build and output directories first
  --skip-deps             Do not rebuild external dependency libraries
  -h, --help              Show this help

Outputs:
  stage_osxcross/build/llvmsdk/dist/llvmsdk-<version>-<triple>.tar.xz
  stage_osxcross/build/llvmsdk/dist/llvm_dependencies-<triple>.tar.xz
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

make_host_writable() {
  local path="$1"

  [[ -d "$path" ]] || return 0
  chmod -R a+rwX "$path" 2>/dev/null || true
  if command -v podman >/dev/null 2>&1; then
    podman unshare chmod -R a+rwX "$path" 2>/dev/null || true
  fi
}

resolve_target() {
  local input="$1"

  case "$input" in
    x86_64|amd64|x64|x86|x86_64-unknown-linux-gnu)
      ARCH="x86_64"
      TARGET_TRIPLE="x86_64-unknown-linux-gnu"
      TARGET_KIND="linux"
      SDK_PACKAGE_TRIPLE="x86_64-unknown-linux-gnu"
      ;;
    aarch64|arm64|aarch64-unknown-linux-gnu)
      ARCH="aarch64"
      TARGET_TRIPLE="aarch64-unknown-linux-gnu"
      TARGET_KIND="linux"
      SDK_PACKAGE_TRIPLE="aarch64-unknown-linux-gnu"
      ;;
    riscv64|riscv64gc|riscv64-unknown-linux-gnu)
      ARCH="riscv64"
      TARGET_TRIPLE="riscv64-unknown-linux-gnu"
      TARGET_KIND="linux"
      SDK_PACKAGE_TRIPLE="riscv64-unknown-linux-gnu"
      ;;
    loongarch64|loong64|loongarch64-unknown-linux-gnu)
      ARCH="loongarch64"
      TARGET_TRIPLE="loongarch64-unknown-linux-gnu"
      TARGET_KIND="linux"
      SDK_PACKAGE_TRIPLE="loongarch64-unknown-linux-gnu"
      ;;
    mingw64|windows|win64|x86_64-w64-windows-gnu)
      ARCH="x86_64"
      TARGET_TRIPLE="x86_64-w64-windows-gnu"
      TARGET_KIND="mingw"
      SDK_PACKAGE_TRIPLE="x86_64-w64-windows-gnu"
      ;;
    *)
      die "unsupported SDK target: $input"
      ;;
  esac
}

TARGET=""
LLVM_VERSION="18.1.8"
LINUX_IMAGE="ghcr.io/zarraxx/develop_suit:llvm-18.1.8"
MINGW_IMAGE="ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8"
JOBS=4
PACKAGE_NAME=""
DEPENDENCY_PACKAGE_NAME=""
PULL=0
CLEAN=0
SKIP_DEPS=0

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
    --llvm-version=*)
      LLVM_VERSION="${1#*=}"
      ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --linux-image=*)
      LINUX_IMAGE="${1#*=}"
      ;;
    --linux-image)
      shift
      [[ $# -gt 0 ]] || die "--linux-image requires a value"
      LINUX_IMAGE="$1"
      ;;
    --mingw-image=*)
      MINGW_IMAGE="${1#*=}"
      ;;
    --mingw-image)
      shift
      [[ $# -gt 0 ]] || die "--mingw-image requires a value"
      MINGW_IMAGE="$1"
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
    --dependency-package-name=*)
      DEPENDENCY_PACKAGE_NAME="${1#*=}"
      ;;
    --dependency-package-name)
      shift
      [[ $# -gt 0 ]] || die "--dependency-package-name requires a value"
      DEPENDENCY_PACKAGE_NAME="$1"
      ;;
    --pull)
      PULL=1
      ;;
    --clean)
      CLEAN=1
      ;;
    --skip-deps)
      SKIP_DEPS=1
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

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET"

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="llvmsdk-${LLVM_VERSION}-${SDK_PACKAGE_TRIPLE}"
fi
if [[ -z "$DEPENDENCY_PACKAGE_NAME" ]]; then
  DEPENDENCY_PACKAGE_NAME="llvm_dependencies-${SDK_PACKAGE_TRIPLE}"
fi

case "$TARGET_KIND" in
  linux)
    BUILD_IMAGE="$LINUX_IMAGE"
    ;;
  mingw)
    BUILD_IMAGE="$MINGW_IMAGE"
    ;;
  *)
    die "unknown target kind: $TARGET_KIND"
    ;;
esac

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
SDK_ROOT="${ROOT_DIR}/build/llvmsdk"
BUILD_DIR="${SDK_ROOT}/build/${TARGET_TRIPLE}"
OUT_BASE="${SDK_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DEPENDENCY_PACKAGE_DIR="${OUT_BASE}/${DEPENDENCY_PACKAGE_NAME}"
DIST_DIR="${SDK_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"
DEPENDENCY_ARCHIVE_PATH="${DIST_DIR}/${DEPENDENCY_PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_llvm_dep.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_llvm_dep.sh"
[[ -f "${MOUNT_ROOT}/container_llvm_sdk.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_llvm_sdk.sh"

make_host_writable "$SDK_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning LLVM SDK target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$DEPENDENCY_PACKAGE_DIR" "$ARCHIVE_PATH" "$DEPENDENCY_ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- LLVM SDK build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- dependency package: ${DEPENDENCY_PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

if [[ "$SKIP_DEPS" -eq 0 ]]; then
  docker run --rm \
    --platform linux/amd64 \
    -v "${MOUNT_ROOT}:/work/mount_root:ro" \
    -v "${CACHE_DIR}:/work/cache" \
    -v "${BUILD_DIR}:/work/build" \
    -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
    --workdir /work \
    -e ARCH="$ARCH" \
    -e TARGET_KIND="$TARGET_KIND" \
    -e TARGET_TRIPLE="$TARGET_TRIPLE" \
    -e LLVM_VERSION="$LLVM_VERSION" \
    -e JOBS="$JOBS" \
    -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
    "$BUILD_IMAGE" \
    /bin/bash /work/mount_root/container_llvm_dep.sh

  rm -rf "$DEPENDENCY_PACKAGE_DIR" "$DEPENDENCY_ARCHIVE_PATH"
  mkdir -p "$DEPENDENCY_PACKAGE_DIR"
  cp -a "${OUT_DIR}/." "$DEPENDENCY_PACKAGE_DIR/"
  tar -C "$OUT_BASE" -cJf "$DEPENDENCY_ARCHIVE_PATH" "$DEPENDENCY_PACKAGE_NAME"
fi

docker run --rm \
  --platform linux/amd64 \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  --workdir /work \
  -e ARCH="$ARCH" \
  -e TARGET_KIND="$TARGET_KIND" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_llvm_sdk.sh

make_host_writable "$SDK_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- LLVM SDK archive ready: ${ARCHIVE_PATH}"
if [[ -f "$DEPENDENCY_ARCHIVE_PATH" ]]; then
  echo "-- LLVM dependency archive ready: ${DEPENDENCY_ARCHIVE_PATH}"
fi
