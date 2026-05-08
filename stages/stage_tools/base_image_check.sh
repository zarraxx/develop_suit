#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stages/stage_tools/base_image_check.sh --arch=<arch> [options]

Options:
  --arch=<arch>       Target arch: x86_64, aarch64, riscv64, loongarch64
  --image=<image>     Base image to check
                      (default: ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-06)
  --jobs=<n>          Parallel build jobs inside container (default: 4)
  --pull              Pull the base image before running
  -h, --help          Show this help
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

ARCH=""
IMAGE="ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-06"
JOBS=4
PULL=0

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
    --pull)
      PULL=1
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

require_command docker

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${BUILD_DIR}/out/${ARCH}"
CONTAINER_NAME="stage-tools-base-check-${ARCH}-$$"
CONTAINER_ID=""

[[ -d "$MOUNT_ROOT" ]] || die "mount root does not exist: $MOUNT_ROOT"
[[ -f "${MOUNT_ROOT}/build_file_package.sh" ]] || die "missing file package script: ${MOUNT_ROOT}/build_file_package.sh"

mkdir -p "$CACHE_DIR" "$BUILD_DIR/out" "$BUILD_DIR/build" "$OUT_DIR"

cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  else
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling base image: ${IMAGE}"
  docker pull --platform linux/amd64 "$IMAGE"
fi

echo "-- checking base image autotools support"
echo "-- image: ${IMAGE}"
echo "-- arch: ${ARCH}"
echo "-- output: ${OUT_DIR}"

CONTAINER_ID="$(
  docker create \
    --name "$CONTAINER_NAME" \
    --platform linux/amd64 \
    -v "${MOUNT_ROOT}:/work/mount_root:ro" \
    -v "${CACHE_DIR}:/work/cache" \
    -v "${BUILD_DIR}/build:/work/build" \
    -v "${BUILD_DIR}/out:/work/out" \
    --workdir /work \
    "$IMAGE" \
    /work/mount_root/build_file_package.sh \
      --arch="$ARCH" \
      --jobs="$JOBS" \
      --cache-dir=/work/cache \
      --out-dir="/work/out/${ARCH}"
)"

docker start -a "$CONTAINER_ID"

echo "-- base image check ok"
echo "-- installed file package under: ${OUT_DIR}"
