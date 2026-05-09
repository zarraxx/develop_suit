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
  ./packages/osxcross/build_mingw64.sh [options]

Options:
  --image=<image>          Build image
                           (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --llvm-version=<ver>     LLVM SDK version (default: 18.1.8)
  --dependency-archive=<tar>
                           llvm_dependencies-x86_64-w64-windows-gnu archive
  --llvmsdk-archive=<tar>  llvmsdk-<ver>-x86_64-w64-windows-gnu archive
  --modules=<list>         Modules to run
                           (default: "liblto xar libtapi cctools")
  --jobs=<n>               Parallel build jobs inside container (default: 4)
  --pull                   Pull build image
  --clean                  Remove this experiment's build/output directories first
  -h, --help               Show this help

This is an experimental Windows-host osxcross build path. It intentionally uses
packages/osxcross/mingw64_mount_root and does not share implementation files
with the Linux-host osxcross package build.
EOF
}

find_default_archive() {
  local name="$1"
  local path=""

  path="${PROJECT_ROOT}/tmp/stage-llvmsdk-run-25543143660-artifacts/llvmsdk-mingw64/${name}"
  if [[ -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  path="$(
    find "${PROJECT_ROOT}/tmp" -name "$name" -type f 2>/dev/null \
      | sort -r \
      | head -n 1
  )"
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  return 1
}

extract_prefix() {
  local archive_path="$1"
  local output_dir="$2"
  local package_dir="$3"
  local tmp_extract="${output_dir}.extract"
  local extracted_dir=""

  [[ -f "$archive_path" ]] || die "archive not found: ${archive_path}"

  rm -rf "$tmp_extract" "$output_dir"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${package_dir}" ]]; then
    extracted_dir="${tmp_extract}/${package_dir}"
  else
    die "could not find ${package_dir} in ${archive_path}"
  fi

  mkdir -p "$(dirname "$output_dir")"
  mv "$extracted_dir" "$output_dir"
  rm -rf "$tmp_extract"
}

TARGET_TRIPLE="x86_64-w64-windows-gnu"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
DEPENDENCY_ARCHIVE=""
LLVMSDK_ARCHIVE=""
CUSTOM_MODULES="liblto xar libtapi cctools"
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image=*|--build-image=*)
      BUILD_IMAGE="${1#*=}"
      ;;
    --image|--build-image)
      shift
      [[ $# -gt 0 ]] || die "$1 requires a value"
      BUILD_IMAGE="$1"
      ;;
    --llvm-version=*)
      LLVM_VERSION="${1#*=}"
      ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --dependency-archive=*|--llvm-deps-archive=*)
      DEPENDENCY_ARCHIVE="${1#*=}"
      ;;
    --dependency-archive|--llvm-deps-archive)
      shift
      [[ $# -gt 0 ]] || die "$1 requires a value"
      DEPENDENCY_ARCHIVE="$1"
      ;;
    --llvmsdk-archive=*)
      LLVMSDK_ARCHIVE="${1#*=}"
      ;;
    --llvmsdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-archive requires a value"
      LLVMSDK_ARCHIVE="$1"
      ;;
    --modules=*)
      CUSTOM_MODULES="${1#*=}"
      ;;
    --modules)
      shift
      [[ $# -gt 0 ]] || die "--modules requires a value"
      CUSTOM_MODULES="$1"
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
require_command tar

if [[ -z "$DEPENDENCY_ARCHIVE" ]]; then
  DEPENDENCY_ARCHIVE="$(find_default_archive "llvm_dependencies-${TARGET_TRIPLE}.tar.xz")" \
    || die "missing llvm_dependencies archive for ${TARGET_TRIPLE}"
fi
if [[ -z "$LLVMSDK_ARCHIVE" ]]; then
  LLVMSDK_ARCHIVE="$(find_default_archive "llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}.tar.xz")" \
    || die "missing llvmsdk archive for ${TARGET_TRIPLE}"
fi

MOUNT_ROOT="${ROOT_DIR}/mingw64_mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_ROOT="${ROOT_DIR}/build/mingw64"
WORK_DIR="${BUILD_ROOT}/work"
OUT_DIR="${BUILD_ROOT}/out/osxcross-${LLVM_VERSION}-${TARGET_TRIPLE}"
DIST_DIR="${BUILD_ROOT}/dist"
DEPS_ROOT="${BUILD_ROOT}/deps/llvm_dependencies-${TARGET_TRIPLE}"
LLVM_SDK_ROOT="${BUILD_ROOT}/deps/llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}"
ARCHIVE_PATH="${DIST_DIR}/osxcross-${LLVM_VERSION}-${TARGET_TRIPLE}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_mingw64_build.sh" ]] || die "missing MinGW container script"
[[ -d "${ROOT_DIR}/upstream" ]] || die "missing osxcross upstream directory"

make_host_writable "$BUILD_ROOT"
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR" "$DIST_DIR" "${BUILD_ROOT}/deps"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning osxcross MinGW experiment"
  rm -rf "$WORK_DIR" "$OUT_DIR" "$ARCHIVE_PATH" "$DEPS_ROOT" "$LLVM_SDK_ROOT"
  mkdir -p "$WORK_DIR" "$OUT_DIR" "${BUILD_ROOT}/deps"
fi

extract_prefix "$DEPENDENCY_ARCHIVE" "$DEPS_ROOT" "llvm_dependencies-${TARGET_TRIPLE}"
extract_prefix "$LLVMSDK_ARCHIVE" "$LLVM_SDK_ROOT" "llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}"

if [[ "$PULL" -eq 1 ]]; then
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- osxcross MinGW experiment"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- dependency archive: ${DEPENDENCY_ARCHIVE}"
echo "-- llvmsdk archive: ${LLVMSDK_ARCHIVE}"
echo "-- output: ${OUT_DIR}"
echo "-- modules: ${CUSTOM_MODULES}"

docker run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mingw64_mount_root:ro" \
  -v "${ROOT_DIR}/upstream:/work/upstream:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${WORK_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/osxcross-mingw64" \
  -v "${DEPS_ROOT}:/work/llvm_dependencies:ro" \
  -v "${LLVM_SDK_ROOT}:/work/llvmsdk:ro" \
  --workdir /work \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e JOBS="$JOBS" \
  -e DEPS_ROOT="/work/llvm_dependencies" \
  -e LLVM_SDK_ROOT="/work/llvmsdk" \
  -e OUT_DIR="/opt/osxcross-mingw64" \
  -e CUSTOM_MODULES="$CUSTOM_MODULES" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mingw64_mount_root/container_mingw64_build.sh

make_host_writable "$BUILD_ROOT"
rm -f "$ARCHIVE_PATH"
tar -C "$(dirname "$OUT_DIR")" -cJf "$ARCHIVE_PATH" "$(basename "$OUT_DIR")"

echo "-- osxcross MinGW archive ready: ${ARCHIVE_PATH}"
