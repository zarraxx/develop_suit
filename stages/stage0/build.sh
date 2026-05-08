#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stages/stage0/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>                  Target arch: x86_64, aarch64, riscv64, loongarch64
  --clean                        Remove the per-arch build directory before configuring
  --jobs=<n>                     Parallel build jobs passed to CMake and BusyBox
  --verbose                      Enable verbose CMake/Ninja/Make output for debugging
  --build-dir=<path>             Override per-arch CMake build directory
  --dist-dir=<path>              Override final output directory (default: <repo>/dist/sysroot/<arch>)
  --config-fragment=<path>       Override BusyBox config fragment
  --llvm-archive=<path>          Override LLVM archive path instead of auto-downloading
  --llvm-source-archive=<path>   Override llvm-project source archive path instead of auto-downloading
  --sysroot-archive=<path>       Override sysroot archive path instead of auto-downloading
  --busybox-archive=<path>       Override BusyBox archive path instead of auto-downloading
  --clang-root=<path>            Use a pre-extracted clang root
  --llvm-source-dir=<path>       Use a pre-extracted llvm-project source tree
  --target-sysroot-dir=<path>    Use a pre-extracted target sysroot
  --busybox-source-dir=<path>    Use a pre-extracted BusyBox source tree
  --cmake-arg=<arg>              Forward an extra argument to CMake configure (repeatable)
  -h, --help                     Show this help
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

copy_tree_clean() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || die "source directory does not exist: $src"

  cmake -E rm -rf "$dst"
  cmake -E make_directory "$dst"
  cp -a "${src}/." "$dst/"
}

ARCH=""
CLEAN=0
JOBS=""
VERBOSE=0
BUILD_DIR=""
DIST_DIR=""
CONFIG_FRAGMENT=""
LLVM_ARCHIVE=""
LLVM_SOURCE_ARCHIVE=""
SYSROOT_ARCHIVE=""
BUSYBOX_ARCHIVE=""
CLANG_ROOT=""
LLVM_SOURCE_DIR=""
TARGET_SYSROOT_DIR=""
BUSYBOX_SOURCE_DIR=""
CMAKE_EXTRA_ARGS=()

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
    --clean)
      CLEAN=1
      ;;
    --verbose)
      VERBOSE=1
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --build-dir=*)
      BUILD_DIR="${1#*=}"
      ;;
    --build-dir)
      shift
      [[ $# -gt 0 ]] || die "--build-dir requires a value"
      BUILD_DIR="$1"
      ;;
    --dist-dir=*)
      DIST_DIR="${1#*=}"
      ;;
    --dist-dir)
      shift
      [[ $# -gt 0 ]] || die "--dist-dir requires a value"
      DIST_DIR="$1"
      ;;
    --config-fragment=*)
      CONFIG_FRAGMENT="${1#*=}"
      ;;
    --config-fragment)
      shift
      [[ $# -gt 0 ]] || die "--config-fragment requires a value"
      CONFIG_FRAGMENT="$1"
      ;;
    --llvm-archive=*)
      LLVM_ARCHIVE="${1#*=}"
      ;;
    --llvm-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvm-archive requires a value"
      LLVM_ARCHIVE="$1"
      ;;
    --llvm-source-archive=*)
      LLVM_SOURCE_ARCHIVE="${1#*=}"
      ;;
    --llvm-source-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvm-source-archive requires a value"
      LLVM_SOURCE_ARCHIVE="$1"
      ;;
    --sysroot-archive=*)
      SYSROOT_ARCHIVE="${1#*=}"
      ;;
    --sysroot-archive)
      shift
      [[ $# -gt 0 ]] || die "--sysroot-archive requires a value"
      SYSROOT_ARCHIVE="$1"
      ;;
    --busybox-archive=*)
      BUSYBOX_ARCHIVE="${1#*=}"
      ;;
    --busybox-archive)
      shift
      [[ $# -gt 0 ]] || die "--busybox-archive requires a value"
      BUSYBOX_ARCHIVE="$1"
      ;;
    --clang-root=*)
      CLANG_ROOT="${1#*=}"
      ;;
    --clang-root)
      shift
      [[ $# -gt 0 ]] || die "--clang-root requires a value"
      CLANG_ROOT="$1"
      ;;
    --llvm-source-dir=*)
      LLVM_SOURCE_DIR="${1#*=}"
      ;;
    --llvm-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--llvm-source-dir requires a value"
      LLVM_SOURCE_DIR="$1"
      ;;
    --target-sysroot-dir=*)
      TARGET_SYSROOT_DIR="${1#*=}"
      ;;
    --target-sysroot-dir)
      shift
      [[ $# -gt 0 ]] || die "--target-sysroot-dir requires a value"
      TARGET_SYSROOT_DIR="$1"
      ;;
    --busybox-source-dir=*)
      BUSYBOX_SOURCE_DIR="${1#*=}"
      ;;
    --busybox-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--busybox-source-dir requires a value"
      BUSYBOX_SOURCE_DIR="$1"
      ;;
    --cmake-arg=*)
      CMAKE_EXTRA_ARGS+=("${1#*=}")
      ;;
    --cmake-arg)
      shift
      [[ $# -gt 0 ]] || die "--cmake-arg requires a value"
      CMAKE_EXTRA_ARGS+=("$1")
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

require_command cmake
require_command cp

ARCH="$(normalize_arch "$ARCH")"
TARGET_TRIPLE="$(target_triple_for_arch "$ARCH")"

if [[ -z "$BUILD_DIR" ]]; then
  BUILD_DIR="${ROOT_DIR}/build/${ARCH}"
fi

if [[ -z "$DIST_DIR" ]]; then
  DIST_DIR="${PROJECT_ROOT}/dist/sysroot/${ARCH}"
fi

BUILD_DIR="$(realpath -m "$BUILD_DIR")"
DIST_DIR="$(realpath -m "$DIST_DIR")"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "Cleaning build directory: ${BUILD_DIR}"
  cmake -E rm -rf "$BUILD_DIR"
fi

cmake_args=(
  -S "$ROOT_DIR"
  -B "$BUILD_DIR"
  "-DSTAGE0_TARGET_TRIPLE=${TARGET_TRIPLE}"
)

if [[ -n "$JOBS" ]]; then
  cmake_args+=("-DSTAGE0_JOBS=${JOBS}")
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  cmake_args+=(
    "-DSTAGE0_VERBOSE_BUILD=ON"
    "-DCMAKE_VERBOSE_MAKEFILE=ON"
  )
fi

if [[ -n "$CONFIG_FRAGMENT" ]]; then
  cmake_args+=("-DSTAGE0_BUSYBOX_CONFIG_FRAGMENT=$(realpath -m "$CONFIG_FRAGMENT")")
fi

if [[ -n "$LLVM_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE0_LLVM_ARCHIVE=$(realpath -m "$LLVM_ARCHIVE")")
fi

if [[ -n "$LLVM_SOURCE_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE0_LLVM_SOURCE_ARCHIVE=$(realpath -m "$LLVM_SOURCE_ARCHIVE")")
fi

if [[ -n "$SYSROOT_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE0_SYSROOT_ARCHIVE=$(realpath -m "$SYSROOT_ARCHIVE")")
fi

if [[ -n "$BUSYBOX_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE0_BUSYBOX_ARCHIVE=$(realpath -m "$BUSYBOX_ARCHIVE")")
fi

if [[ -n "$CLANG_ROOT" ]]; then
  cmake_args+=("-DSTAGE0_CLANG_ROOT=$(realpath -m "$CLANG_ROOT")")
fi

if [[ -n "$LLVM_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE0_LLVM_SOURCE_DIR=$(realpath -m "$LLVM_SOURCE_DIR")")
fi

if [[ -n "$TARGET_SYSROOT_DIR" ]]; then
  cmake_args+=("-DSTAGE0_TARGET_SYSROOT_DIR=$(realpath -m "$TARGET_SYSROOT_DIR")")
fi

if [[ -n "$BUSYBOX_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE0_BUSYBOX_SOURCE_DIR=$(realpath -m "$BUSYBOX_SOURCE_DIR")")
fi

if [[ ${#CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
  cmake_args+=("${CMAKE_EXTRA_ARGS[@]}")
fi

echo "Configuring stage0 for arch=${ARCH} target=${TARGET_TRIPLE}"
cmake "${cmake_args[@]}"

build_args=(
  --build "$BUILD_DIR"
  --target stage0-busybox-rootfs
)

if [[ -n "$JOBS" ]]; then
  build_args+=(--parallel "$JOBS")
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  build_args+=(--verbose)
fi

echo "Building stage0 BusyBox rootfs"
cmake "${build_args[@]}"

ROOTFS_DIR="${BUILD_DIR}/out/${TARGET_TRIPLE}/rootfs"
[[ -d "$ROOTFS_DIR" ]] || die "expected rootfs output not found: $ROOTFS_DIR"

echo "Publishing rootfs to ${DIST_DIR}"
copy_tree_clean "$ROOTFS_DIR" "$DIST_DIR"

echo "Done"
echo "  arch        : ${ARCH}"
echo "  target      : ${TARGET_TRIPLE}"
echo "  build dir   : ${BUILD_DIR}"
echo "  source root : ${ROOTFS_DIR}"
echo "  dist dir    : ${DIST_DIR}"
