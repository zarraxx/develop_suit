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
  ./packages/osxcross/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>           Host arch for produced Linux osxcross tools:
                          x86_64, aarch64, riscv64, loongarch64
  --build-image=<image>   x86_64 build container image
                          (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --llvm-version=<ver>    LLVM SDK version (default: 18.1.8)
  --llvmsdk-dir=<dir>     host-arch LLVM SDK prefix directory
                          (default: <repo>/packages/llvm/build/out/llvmsdk-<ver>-<triple>)
  --llvmsdk-archive=<tar> host-arch LLVM SDK archive to extract when no dir is present
                          (default: local packages/llvm/build/dist or tmp artifact)
  --llvm-deps-dir=<dir>   host-arch LLVM dependency prefix directory
                          (default: <repo>/packages/llvm_dependencies/build/out/llvm_dependencies-<triple>)
  --llvm-deps-archive=<tar>
                          host-arch LLVM dependency archive to extract when no dir is present
                          (default: local packages/llvm_dependencies/build/dist or tmp artifact)
  --jobs=<n>              Parallel build jobs inside container (default: 4)
  --package-name=<name>   Override the top-level directory and tarball stem
  --modules=<list>        Custom modules to run inside the container
                          (default: "xar libtapi liblto cctools wrapper cmake_helper macports_helper";
                          available: xar libtapi liblto cctools wrapper cmake_helper macports_helper)
  --pull                  Pull build image
  --clean                 Remove this arch's build/output directories first
  --refresh-deps          Re-extract prepared LLVM SDK/dependency prefix
  -h, --help              Show this help

This custom path intentionally runs builds in the x86_64 stage_llvm image while
using the host-arch LLVM SDK only as dependency headers/libraries and as the
source of libLLVM/libLTO for cctools.

Outputs:
  packages/osxcross/build/dist/osxcross-<llvm-version>-<triple>.tar.xz
EOF
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

target_triple_for_arch() {
  case "$1" in
    x86_64)
      echo "x86_64-unknown-linux-gnu"
      ;;
    aarch64)
      echo "aarch64-unknown-linux-gnu"
      ;;
    riscv64)
      echo "riscv64-unknown-linux-gnu"
      ;;
    loongarch64)
      echo "loongarch64-unknown-linux-gnu"
      ;;
    *)
      die "no target triple mapping for arch: $1"
      ;;
  esac
}

validate_llvmsdk_dir() {
  local sdk_dir="$1"

  [[ -d "$sdk_dir" ]] || die "LLVM SDK directory not found: ${sdk_dir}"
  [[ -x "${sdk_dir}/bin/llvm-config" ]] || die "missing LLVM SDK llvm-config: ${sdk_dir}/bin/llvm-config"
  [[ -f "${sdk_dir}/include/llvm-c/lto.h" ]] || die "missing LLVM SDK libLTO header: ${sdk_dir}/include/llvm-c/lto.h"
  [[ -f "${sdk_dir}/lib/libLTO.so" ]] || die "missing LLVM SDK libLTO library: ${sdk_dir}/lib/libLTO.so"
  [[ -f "${sdk_dir}/lib/libLLVM.so" || -f "${sdk_dir}/lib/libLLVM-${LLVM_VERSION%%.*}.so" ]] \
    || die "missing LLVM SDK libLLVM library under: ${sdk_dir}/lib"
}

validate_llvm_deps_dir() {
  local deps_dir="$1"

  [[ -d "$deps_dir" ]] || die "LLVM dependency directory not found: ${deps_dir}"
  [[ -f "${deps_dir}/include/zlib.h" ]] || die "missing LLVM dependency zlib header: ${deps_dir}/include/zlib.h"
  [[ -f "${deps_dir}/include/bzlib.h" ]] || die "missing LLVM dependency bzip2 header: ${deps_dir}/include/bzlib.h"
  [[ -f "${deps_dir}/include/lzma.h" ]] || die "missing LLVM dependency xz header: ${deps_dir}/include/lzma.h"
  [[ -d "${deps_dir}/include/libxml2" ]] || die "missing LLVM dependency libxml2 headers: ${deps_dir}/include/libxml2"
  [[ -f "${deps_dir}/include/openssl/evp.h" ]] || die "missing LLVM dependency OpenSSL header: ${deps_dir}/include/openssl/evp.h"
  [[ -f "${deps_dir}/lib/libz.so" ]] || die "missing LLVM dependency zlib library: ${deps_dir}/lib/libz.so"
  [[ -f "${deps_dir}/lib/libbz2.so" ]] || die "missing LLVM dependency bzip2 library: ${deps_dir}/lib/libbz2.so"
  [[ -f "${deps_dir}/lib/liblzma.so" ]] || die "missing LLVM dependency xz library: ${deps_dir}/lib/liblzma.so"
  [[ -f "${deps_dir}/lib/libxml2.so" ]] || die "missing LLVM dependency libxml2 library: ${deps_dir}/lib/libxml2.so"
  [[ -f "${deps_dir}/lib/libcrypto.so" ]] || die "missing LLVM dependency libcrypto library: ${deps_dir}/lib/libcrypto.so"
}

find_local_llvmsdk_archive() {
  local archive_name="llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}.tar.xz"
  local archive_path=""

  archive_path="${PROJECT_ROOT}/packages/llvm/build/dist/${archive_name}"
  if [[ -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  archive_path="$(
    find "${PROJECT_ROOT}/tmp" -path "*/llvmsdk-${ARCH}/${archive_name}" -type f 2>/dev/null \
      | sort -r \
      | head -n 1
  )"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  return 1
}

find_local_llvm_deps_archive() {
  local archive_name="llvm_dependencies-${TARGET_TRIPLE}.tar.xz"
  local archive_path=""

  archive_path="${PROJECT_ROOT}/packages/llvm_dependencies/build/dist/${archive_name}"
  if [[ -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  archive_path="$(
    find "${PROJECT_ROOT}/tmp" -path "*/llvm_dependencies-${ARCH}/${archive_name}" -type f 2>/dev/null \
      | sort -r \
      | head -n 1
  )"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  archive_path="$(
    find "${PROJECT_ROOT}/tmp" -name "$archive_name" -type f 2>/dev/null \
      | sort -r \
      | head -n 1
  )"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  return 1
}

prepare_llvmsdk_from_archive() {
  local sdk_dir="$1"
  local archive_path="$2"
  local tmp_extract="${sdk_dir}.extract"
  local extracted_dir=""
  local package_dir="llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}"
  local marker="${sdk_dir}/.package-osxcross-llvmsdk-ready"
  local deps_version="package-osxcross-llvmsdk-v1"

  if [[ "$REFRESH_DEPS" -eq 0 && -f "$marker" ]] \
      && grep -qx "archive=${archive_path}" "$marker" \
      && grep -qx "version=${deps_version}" "$marker"; then
    echo "-- LLVM SDK already prepared: ${sdk_dir}" >&2
    validate_llvmsdk_dir "$sdk_dir"
    return 0
  fi

  echo "-- extracting LLVM SDK archive: ${archive_path}" >&2
  rm -rf "$tmp_extract" "$sdk_dir"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${package_dir}" ]]; then
    extracted_dir="${tmp_extract}/${package_dir}"
  elif [[ -x "${tmp_extract}/bin/llvm-config" ]]; then
    extracted_dir="$tmp_extract"
  else
    die "could not find LLVM SDK prefix in archive: ${archive_path}"
  fi

  mkdir -p "$(dirname "$sdk_dir")"
  mv "$extracted_dir" "$sdk_dir"
  rm -rf "$tmp_extract"
  {
    echo "archive=${archive_path}"
    echo "version=${deps_version}"
  } >"$marker"

  validate_llvmsdk_dir "$sdk_dir"
}

prepare_llvm_deps_from_archive() {
  local deps_dir="$1"
  local archive_path="$2"
  local tmp_extract="${deps_dir}.extract"
  local extracted_dir=""
  local package_dir="llvm_dependencies-${TARGET_TRIPLE}"
  local marker="${deps_dir}/.package-osxcross-llvm-deps-ready"
  local deps_version="package-osxcross-llvm-deps-v1"

  if [[ "$REFRESH_DEPS" -eq 0 && -f "$marker" ]] \
      && grep -qx "archive=${archive_path}" "$marker" \
      && grep -qx "version=${deps_version}" "$marker"; then
    echo "-- LLVM dependencies already prepared: ${deps_dir}" >&2
    validate_llvm_deps_dir "$deps_dir"
    return 0
  fi

  echo "-- extracting LLVM dependency archive: ${archive_path}" >&2
  rm -rf "$tmp_extract" "$deps_dir"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${package_dir}" ]]; then
    extracted_dir="${tmp_extract}/${package_dir}"
  elif [[ -f "${tmp_extract}/include/zlib.h" ]]; then
    extracted_dir="$tmp_extract"
  else
    die "could not find LLVM dependency prefix in archive: ${archive_path}"
  fi

  mkdir -p "$(dirname "$deps_dir")"
  mv "$extracted_dir" "$deps_dir"
  rm -rf "$tmp_extract"
  {
    echo "archive=${archive_path}"
    echo "version=${deps_version}"
  } >"$marker"

  validate_llvm_deps_dir "$deps_dir"
}

prepare_llvmsdk() {
  local default_sdk_dir="${PROJECT_ROOT}/packages/llvm/build/out/llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}"
  local prepared_sdk_dir="${BUILD_DIR}/deps/${ARCH}/llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}"
  local archive_path=""

  if [[ -n "$LLVMSDK_DIR" ]]; then
    validate_llvmsdk_dir "$LLVMSDK_DIR"
    printf '%s\n' "$LLVMSDK_DIR"
    return 0
  fi

  if [[ -n "$LLVMSDK_ARCHIVE" ]]; then
    archive_path="$LLVMSDK_ARCHIVE"
    [[ -f "$archive_path" ]] || die "LLVM SDK archive not found: ${archive_path}"
    prepare_llvmsdk_from_archive "$prepared_sdk_dir" "$archive_path"
    printf '%s\n' "$prepared_sdk_dir"
    return 0
  fi

  if [[ -d "$default_sdk_dir" ]]; then
    validate_llvmsdk_dir "$default_sdk_dir"
    printf '%s\n' "$default_sdk_dir"
    return 0
  fi

  archive_path="$(find_local_llvmsdk_archive)" || die "local LLVM SDK archive not found for ${TARGET_TRIPLE}"
  [[ -f "$archive_path" ]] || die "LLVM SDK archive not found: ${archive_path}"
  prepare_llvmsdk_from_archive "$prepared_sdk_dir" "$archive_path"
  printf '%s\n' "$prepared_sdk_dir"
}

prepare_llvm_deps() {
  local default_deps_dir="${PROJECT_ROOT}/packages/llvm_dependencies/build/out/llvm_dependencies-${TARGET_TRIPLE}"
  local prepared_deps_dir="${BUILD_DIR}/deps/${ARCH}/llvm_dependencies-${TARGET_TRIPLE}"
  local archive_path=""

  if [[ -n "$LLVM_DEPS_DIR" ]]; then
    validate_llvm_deps_dir "$LLVM_DEPS_DIR"
    printf '%s\n' "$LLVM_DEPS_DIR"
    return 0
  fi

  if [[ -n "$LLVM_DEPS_ARCHIVE" ]]; then
    archive_path="$LLVM_DEPS_ARCHIVE"
    [[ -f "$archive_path" ]] || die "LLVM dependency archive not found: ${archive_path}"
    prepare_llvm_deps_from_archive "$prepared_deps_dir" "$archive_path"
    printf '%s\n' "$prepared_deps_dir"
    return 0
  fi

  if [[ -d "$default_deps_dir" ]]; then
    validate_llvm_deps_dir "$default_deps_dir"
    printf '%s\n' "$default_deps_dir"
    return 0
  fi

  archive_path="$(find_local_llvm_deps_archive)" || die "local LLVM dependency archive not found for ${TARGET_TRIPLE}"
  [[ -f "$archive_path" ]] || die "LLVM dependency archive not found: ${archive_path}"
  prepare_llvm_deps_from_archive "$prepared_deps_dir" "$archive_path"
  printf '%s\n' "$prepared_deps_dir"
}

install_sdk_package_tools() {
  local out_dir="$1"
  local upstream_tools="${ROOT_DIR}/upstream/osxcross/tools"
  local sdk_tools_dir="${out_dir}/tools"

  mkdir -p "$sdk_tools_dir"

  install -m 0755 "${upstream_tools}/gen_sdk_package.sh" "$sdk_tools_dir/"
  install -m 0755 "${upstream_tools}/gen_sdk_package_tools.sh" "$sdk_tools_dir/"
  install -m 0755 "${upstream_tools}/gen_sdk_package_darling_dmg.sh" "$sdk_tools_dir/"
  install -m 0755 "${upstream_tools}/gen_sdk_package_p7zip.sh" "$sdk_tools_dir/"
  install -m 0755 "${upstream_tools}/gen_sdk_package_pbzx.sh" "$sdk_tools_dir/"
  install -m 0755 "${upstream_tools}/gen_sdk_package_tools_dmg.sh" "$sdk_tools_dir/"
  install -m 0755 "${upstream_tools}/mount_xcode_image.sh" "$sdk_tools_dir/"
}

ARCH=""
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
LLVM_VERSION="18.1.8"
LLVMSDK_DIR=""
LLVMSDK_ARCHIVE=""
LLVM_DEPS_DIR=""
LLVM_DEPS_ARCHIVE=""
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
CUSTOM_MODULES="xar libtapi liblto cctools wrapper cmake_helper macports_helper"
PULL=0
CLEAN=0
REFRESH_DEPS=0

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
    --build-image=*)
      BUILD_IMAGE="${1#*=}"
      ;;
    --build-image)
      shift
      [[ $# -gt 0 ]] || die "--build-image requires a value"
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
    --llvmsdk-dir=*)
      LLVMSDK_DIR="${1#*=}"
      ;;
    --llvmsdk-dir)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-dir requires a value"
      LLVMSDK_DIR="$1"
      ;;
    --llvmsdk-archive=*)
      LLVMSDK_ARCHIVE="${1#*=}"
      ;;
    --llvmsdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-archive requires a value"
      LLVMSDK_ARCHIVE="$1"
      ;;
    --llvm-deps-dir=*)
      LLVM_DEPS_DIR="${1#*=}"
      ;;
    --llvm-deps-dir)
      shift
      [[ $# -gt 0 ]] || die "--llvm-deps-dir requires a value"
      LLVM_DEPS_DIR="$1"
      ;;
    --llvm-deps-archive=*)
      LLVM_DEPS_ARCHIVE="${1#*=}"
      ;;
    --llvm-deps-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvm-deps-archive requires a value"
      LLVM_DEPS_ARCHIVE="$1"
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
    --modules=*)
      CUSTOM_MODULES="${1#*=}"
      ;;
    --modules)
      shift
      [[ $# -gt 0 ]] || die "--modules requires a value"
      CUSTOM_MODULES="$1"
      ;;
    --pull)
      PULL=1
      ;;
    --clean)
      CLEAN=1
      ;;
    --refresh-deps)
      REFRESH_DEPS=1
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
TARGET_TRIPLE="$(target_triple_for_arch "$ARCH")"
BUILD_PLATFORM="linux/amd64"
if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="osxcross-${LLVM_VERSION}-${TARGET_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_DIR="${ROOT_DIR}/build"
OUT_BASE="${BUILD_DIR}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${BUILD_DIR}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -d "$MOUNT_ROOT" ]] || die "mount root does not exist: $MOUNT_ROOT"
[[ -f "${MOUNT_ROOT}/container_custom_build.sh" ]] || die "missing custom container build script"
[[ -d "${ROOT_DIR}/upstream" ]] || die "upstream directory does not exist: ${ROOT_DIR}/upstream"

make_host_writable "$BUILD_DIR"
mkdir -p "$CACHE_DIR" "$BUILD_DIR/build" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning osxcross package build/output: ${ARCH}"
  make_host_writable "$BUILD_DIR"
  rm -rf "${BUILD_DIR}/build/${ARCH}" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform "$BUILD_PLATFORM" "$BUILD_IMAGE"
fi

LLVMSDK_ROOT="$(prepare_llvmsdk)"
LLVM_DEPS_ROOT="$(prepare_llvm_deps)"

echo "-- osxcross package build"
echo "-- build image: ${BUILD_IMAGE}"
echo "-- build platform: ${BUILD_PLATFORM}"
echo "-- host arch: ${ARCH}"
echo "-- host triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- host LLVM dependencies: ${LLVM_DEPS_ROOT}"
echo "-- host LLVM SDK: ${LLVMSDK_ROOT}"
echo "-- output: ${OUT_DIR}"
echo "-- archive: ${ARCHIVE_PATH}"
echo "-- modules: ${CUSTOM_MODULES}"

docker run --rm \
  --platform "$BUILD_PLATFORM" \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${ROOT_DIR}/upstream:/work/upstream:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}/build:/work/build" \
  -v "${OUT_DIR}:/opt/osxcross" \
  -v "${LLVM_DEPS_ROOT}:/work/llvm_dependencies/${ARCH}:ro" \
  -v "${LLVMSDK_ROOT}:/work/llvmsdk/${ARCH}:ro" \
  --workdir /work \
  -e ARCH="$ARCH" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e JOBS="$JOBS" \
  -e DEPS_ROOT="/work/llvm_dependencies/${ARCH}" \
  -e LLVM_SDK_ROOT="/work/llvmsdk/${ARCH}" \
  -e OUT_DIR="/opt/osxcross" \
  -e CUSTOM_MODULES="$CUSTOM_MODULES" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_custom_build.sh

make_host_writable "$BUILD_DIR"
install_sdk_package_tools "$OUT_DIR"
rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- osxcross package build ok"
echo "-- installed under: ${OUT_DIR}"
echo "-- archive ready: ${ARCHIVE_PATH}"
