#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage-mingw64/build_mingw64_native.sh [options]

Options:
  --image=<image>          Linux builder image that already contains stage-mingw64
                           (default: localhost/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>               Parallel build jobs inside container (default: 4)
  --pull                   Pull the builder image before running
  --clean                  Remove native build/output directories first
  -h, --help               Show this help

Output:
  stage-mingw64/build/out/mingw64-native/llvm18.1.8
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

IMAGE="localhost/develop_suit:llvm-with-mingw64-18.1.8"
JOBS=4
PULL=0
CLEAN=0
BUILDER_PLATFORM="linux/amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
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

require_command docker

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_DIR="${ROOT_DIR}/build"
NATIVE_BUILD_DIR="${BUILD_DIR}/native-build"
OUT_DIR="${BUILD_DIR}/out/mingw64-native"

[[ -d "$MOUNT_ROOT" ]] || die "mount root does not exist: $MOUNT_ROOT"
[[ -f "${MOUNT_ROOT}/container_native_build.sh" ]] || die "missing container build script: ${MOUNT_ROOT}/container_native_build.sh"

make_host_writable "$NATIVE_BUILD_DIR"
make_host_writable "$OUT_DIR"
mkdir -p "$CACHE_DIR" "$NATIVE_BUILD_DIR" "$OUT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning stage-mingw64 native build/output"
  make_host_writable "$NATIVE_BUILD_DIR"
  make_host_writable "$OUT_DIR"
  rm -rf "$NATIVE_BUILD_DIR" "$OUT_DIR"
  mkdir -p "$NATIVE_BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling builder image: ${IMAGE}"
  docker pull --platform "$BUILDER_PLATFORM" "$IMAGE"
fi

echo "-- stage-mingw64 native build"
echo "-- image: ${IMAGE}"
echo "-- builder platform: ${BUILDER_PLATFORM}"
echo "-- output: ${OUT_DIR}/llvm18.1.8"

docker run --rm \
  --platform "$BUILDER_PLATFORM" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${NATIVE_BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/work/out" \
  --workdir /work \
  "$IMAGE" \
  /work/mount_root/container_native_build.sh \
    --jobs="$JOBS" \
    --cache-dir=/work/cache \
    --build-dir=/work/build \
    --out-dir=/work/out

make_host_writable "$NATIVE_BUILD_DIR"
make_host_writable "$OUT_DIR"

echo "-- stage-mingw64 native build ok"
echo "-- installed under: ${OUT_DIR}/llvm18.1.8"
