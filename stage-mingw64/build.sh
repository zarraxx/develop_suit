#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage-mingw64/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>            Host arch for the produced Linux tools
                           x86_64, aarch64, riscv64, loongarch64
  --image=<image>          Builder image
                           (default: ghcr.io/zarraxx/develop_suit:llvm-18.1.8)
  --jobs=<n>               Parallel build jobs inside container (default: 4)
  --pull                   Pull the builder image before running
  --clean                  Remove this arch's build/output directories first
  --mingw-archive=<path>   Use a local MinGW archive instead of downloading
  -h, --help               Show this help

Output:
  stage-mingw64/build/out/<arch>
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
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

make_host_writable() {
  local path="$1"

  [[ -d "$path" ]] || return 0

  chmod -R a+rwX "$path" 2>/dev/null || true
  if command -v podman >/dev/null 2>&1; then
    podman unshare chmod -R a+rwX "$path" 2>/dev/null || true
  fi
}

ARCH=""
IMAGE="ghcr.io/zarraxx/develop_suit:llvm-18.1.8"
JOBS=4
PULL=0
CLEAN=0
MINGW_ARCHIVE=""

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
    arch=*)
      ARCH="${1#*=}"
      ;;
    --image=*)
      IMAGE="${1#*=}"
      ;;
    --image)
      shift
      [[ $# -gt 0 ]] || die "--image requires a value"
      IMAGE="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --mingw-archive=*)
      MINGW_ARCHIVE="${1#*=}"
      ;;
    --mingw-archive)
      shift
      [[ $# -gt 0 ]] || die "--mingw-archive requires a value"
      MINGW_ARCHIVE="$1"
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

[[ -n "$ARCH" ]] || die "--arch is required"
ARCH="$(normalize_arch "$ARCH")"
BUILDER_PLATFORM="linux/amd64"

require_command docker

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${BUILD_DIR}/out/${ARCH}"

[[ -d "$MOUNT_ROOT" ]] || die "mount root does not exist: $MOUNT_ROOT"
[[ -f "${MOUNT_ROOT}/container_build.sh" ]] || die "missing container build script: ${MOUNT_ROOT}/container_build.sh"

make_host_writable "$BUILD_DIR"
mkdir -p "$CACHE_DIR" "$BUILD_DIR/build" "$BUILD_DIR/out" "$OUT_DIR"

if [[ -n "$MINGW_ARCHIVE" ]]; then
  [[ -f "$MINGW_ARCHIVE" ]] || die "MinGW archive does not exist: $MINGW_ARCHIVE"
  cp -f "$MINGW_ARCHIVE" "${CACHE_DIR}/compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning stage-mingw64 arch build/output: ${ARCH}"
  make_host_writable "$BUILD_DIR"
  rm -rf "${BUILD_DIR}/build/${ARCH}" "$OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling builder image: ${IMAGE}"
  docker pull --platform "$BUILDER_PLATFORM" "$IMAGE"
fi

echo "-- stage-mingw64 build"
echo "-- image: ${IMAGE}"
echo "-- arch: ${ARCH}"
echo "-- builder platform: ${BUILDER_PLATFORM}"
echo "-- output: ${OUT_DIR}"

docker run --rm \
  --platform "$BUILDER_PLATFORM" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}/build:/work/build" \
  -v "${BUILD_DIR}/out:/work/out" \
  --workdir /work \
  "$IMAGE" \
  /work/mount_root/container_build.sh \
    --arch="$ARCH" \
    --jobs="$JOBS" \
    --cache-dir=/work/cache \
    --build-dir=/work/build \
    --out-dir="/work/out/${ARCH}"

make_host_writable "$BUILD_DIR"

echo "-- stage-mingw64 build ok"
echo "-- installed overlay under: ${OUT_DIR}"
