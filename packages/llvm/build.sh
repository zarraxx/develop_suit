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
  ./packages/llvm/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>       SDK target, see list above
  --arch=<target>         Alias for --target
  --llvm-version=<ver>    LLVM version (default: 18.1.8)
  --image=<image>         Build image for every target
                          (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>              Parallel build jobs inside container (default: 4)
  --package-name=<name>   Override the top-level directory and tarball stem
  --dependency-package-name=<name>
                          Override dependency tarball top-level directory name
  --dependency-archive=<tar>
                          Extract a prebuilt llvm_dependencies tarball before SDK build
  --pull                  Pull the selected build image before building
  --clean                 Remove this target's build and output directories first
  -h, --help              Show this help

Outputs:
  packages/llvm/build/dist/llvmsdk-<version>-<triple>.tar.xz
EOF
}

find_default_dependency_archive() {
  local archive_name="llvm_dependencies-${SDK_PACKAGE_TRIPLE}.tar.xz"
  local archive_path="${PROJECT_ROOT}/packages/llvm_dependencies/build/dist/${archive_name}"

  [[ -f "$archive_path" ]] || return 1
  printf '%s\n' "$archive_path"
}

prepare_dependencies_from_archive() {
  local archive_path="$1"
  local tmp_extract="${OUT_DIR}.deps-extract"
  local extracted_dir=""

  [[ -f "$archive_path" ]] || die "dependency archive not found: ${archive_path}"

  echo "-- extracting dependency archive: ${archive_path}"
  rm -rf "$tmp_extract" "$OUT_DIR"
  mkdir -p "$tmp_extract" "$OUT_DIR"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${DEPENDENCY_PACKAGE_NAME}" ]]; then
    extracted_dir="${tmp_extract}/${DEPENDENCY_PACKAGE_NAME}"
  elif [[ -f "${tmp_extract}/README.llvmsdk-deps" ]]; then
    extracted_dir="$tmp_extract"
  else
    die "could not find dependency prefix in archive: ${archive_path}"
  fi

  cp -a "${extracted_dir}/." "$OUT_DIR/"
  rm -rf "$tmp_extract"
}

TARGET=""
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
DEPENDENCY_PACKAGE_NAME=""
DEPENDENCY_ARCHIVE=""
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
    --llvm-version=*)
      LLVM_VERSION="${1#*=}"
      ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
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
    --dependency-archive=*)
      DEPENDENCY_ARCHIVE="${1#*=}"
      ;;
    --dependency-archive)
      shift
      [[ $# -gt 0 ]] || die "--dependency-archive requires a value"
      DEPENDENCY_ARCHIVE="$1"
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
    --sdk-only|--skip-deps)
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "LLVM SDK target"

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="llvmsdk-${LLVM_VERSION}-${SDK_PACKAGE_TRIPLE}"
fi
if [[ -z "$DEPENDENCY_PACKAGE_NAME" ]]; then
  DEPENDENCY_PACKAGE_NAME="llvm_dependencies-${SDK_PACKAGE_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
SDK_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${SDK_ROOT}/work/${TARGET_TRIPLE}"
OUT_BASE="${SDK_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${SDK_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_llvm_sdk.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_llvm_sdk.sh"

make_host_writable "$SDK_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning LLVM SDK target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

if [[ -z "$DEPENDENCY_ARCHIVE" ]]; then
  DEPENDENCY_ARCHIVE="$(find_default_dependency_archive)" \
    || die "dependency archive not provided and default archive was not found for ${TARGET_TRIPLE}"
fi
prepare_dependencies_from_archive "$DEPENDENCY_ARCHIVE"

echo "-- LLVM SDK build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- dependency archive: ${DEPENDENCY_ARCHIVE}"
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
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_llvm_sdk.sh

make_host_writable "$SDK_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- LLVM SDK archive ready: ${ARCHIVE_PATH}"
