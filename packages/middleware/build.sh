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
  ./packages/middleware/build.sh --target=x86_64 [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>                 Package target, see list above
  --arch=<target>                   Alias for --target
  --redis-version=<ver>             Redis version (default: 7.4.9)
  --go-version=<ver>                Go toolchain version (default: 1.25.10)
  --minio-ref=<ref>                 MinIO tag/ref (default: RELEASE.2024-06-22T05-26-45Z)
  --etcd-version=<ver>              etcd version (default: 3.6.12)
  --runtime=<docker|podman>         Container runtime override
  --image=<image>                   Build image
  --jobs=<n>                        Parallel build jobs inside container (default: 4)
  --package-name=<name>             Override output package name
  --pull                            Pull build image before building
  --clean                           Remove target build/output directories first
  -h, --help                        Show this help

Outputs:
  packages/middleware/build/dist/middleware-<triple>.tar.xz
EOF
}

TARGET=""
REDIS_VERSION="7.4.9"
GO_VERSION="1.25.10"
MINIO_REF="RELEASE.2024-06-22T05-26-45Z"
ETCD_VERSION="3.6.12"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
REQUESTED_RUNTIME=""
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch) shift; [[ $# -gt 0 ]] || die "$1 requires a value"; TARGET="$1" ;;
    --redis-version=*) REDIS_VERSION="${1#*=}" ;;
    --redis-version) shift; [[ $# -gt 0 ]] || die "--redis-version requires a value"; REDIS_VERSION="$1" ;;
    --go-version=*) GO_VERSION="${1#*=}" ;;
    --go-version) shift; [[ $# -gt 0 ]] || die "--go-version requires a value"; GO_VERSION="$1" ;;
    --minio-ref=*) MINIO_REF="${1#*=}" ;;
    --minio-ref) shift; [[ $# -gt 0 ]] || die "--minio-ref requires a value"; MINIO_REF="$1" ;;
    --etcd-version=*) ETCD_VERSION="${1#*=}" ;;
    --etcd-version) shift; [[ $# -gt 0 ]] || die "--etcd-version requires a value"; ETCD_VERSION="$1" ;;
    --runtime=*) REQUESTED_RUNTIME="${1#*=}" ;;
    --runtime) shift; [[ $# -gt 0 ]] || die "--runtime requires a value"; REQUESTED_RUNTIME="$1" ;;
    --image=*|--linux-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image) shift; [[ $# -gt 0 ]] || die "--image requires a value"; BUILD_IMAGE="$1" ;;
    --jobs=*) JOBS="${1#*=}" ;;
    --jobs) shift; [[ $# -gt 0 ]] || die "--jobs requires a value"; JOBS="$1" ;;
    --package-name=*) PACKAGE_NAME="${1#*=}" ;;
    --package-name) shift; [[ $# -gt 0 ]] || die "--package-name requires a value"; PACKAGE_NAME="$1" ;;
    --pull) PULL=1 ;;
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "middleware package target"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "middleware supports Linux x86_64/aarch64/riscv64/loongarch64 and MinGW x86_64 package targets; got ${TARGET_KIND}:${ARCH}" ;;
esac

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="middleware-${PACKAGE_TRIPLE}"
fi

CONTAINER_RUNTIME="$(resolve_container_runtime "$REQUESTED_RUNTIME")"
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_middleware.sh" ]] || die "missing container script"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"
make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_BASE"
make_host_writable "$OUT_DIR"
make_host_writable "$DIST_DIR"
make_host_writable "$ARCHIVE_PATH"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning middleware target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  "$CONTAINER_RUNTIME" pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- middleware build"
echo "-- runtime: ${CONTAINER_RUNTIME}"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

"$CONTAINER_RUNTIME" run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  --workdir /work \
  -e "ARCH=${ARCH}" \
  -e "TARGET_KIND=${TARGET_KIND}" \
  -e "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  -e "JOBS=${JOBS}" \
  -e "SDK_PREFIX=/opt/${PACKAGE_NAME}" \
  -e "REDIS_VERSION=${REDIS_VERSION}" \
  -e "GO_VERSION=${GO_VERSION}" \
  -e "MINIO_REF=${MINIO_REF}" \
  -e "ETCD_VERSION=${ETCD_VERSION}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_middleware.sh

make_host_writable "$OUT_DIR"
normalize_package_permissions "$OUT_DIR"
if [[ "${TARGET_KIND}" == "mingw" ]]; then
  materialize_symlinks "$OUT_DIR"
  normalize_package_permissions "$OUT_DIR"
fi

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"
chmod 664 "$ARCHIVE_PATH"

echo "-- middleware archive ready: ${ARCHIVE_PATH}"
