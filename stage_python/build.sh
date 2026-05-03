#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage_python/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>                Target arch: x86_64, aarch64, riscv64, loongarch64
  --clean                      Remove the per-arch build directory before configuring
  --jobs=<n>                   Parallel build jobs passed to CMake and make
  --verbose                    Enable verbose build output
  --build-dir=<path>           Override per-arch CMake build directory
  --dist-dir=<path>            Override final output directory (default: <repo>/dist/stage_python/<arch>)
  --input-rootfs-dir=<path>    Override input rootfs directory (default: <repo>/dist/stage1/<arch>)
  --install-prefix=<path>      Install prefix inside the target rootfs (default: /usr)
  --llvm-archive=<path>        Override LLVM archive path instead of auto-downloading
  --clang-root=<path>          Use a pre-extracted clang root
  --ninja-archive=<path>       Override ninja source archive
  --bison-archive=<path>       Override bison source archive
  --flex-archive=<path>        Override flex source archive
  --ninja-source-dir=<path>    Use a pre-extracted ninja source tree
  --bison-source-dir=<path>    Use a pre-extracted bison source tree
  --flex-source-dir=<path>     Use a pre-extracted flex source tree
  --cmake-arg=<arg>            Forward an extra argument to CMake configure (repeatable)
  -h, --help                   Show this help
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
INPUT_ROOTFS_DIR=""
INSTALL_PREFIX="/usr"
LLVM_ARCHIVE=""
CLANG_ROOT=""
NINJA_ARCHIVE=""
BISON_ARCHIVE=""
FLEX_ARCHIVE=""
NINJA_SOURCE_DIR=""
BISON_SOURCE_DIR=""
FLEX_SOURCE_DIR=""
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
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --verbose)
      VERBOSE=1
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
    --input-rootfs-dir=*)
      INPUT_ROOTFS_DIR="${1#*=}"
      ;;
    --input-rootfs-dir)
      shift
      [[ $# -gt 0 ]] || die "--input-rootfs-dir requires a value"
      INPUT_ROOTFS_DIR="$1"
      ;;
    --install-prefix=*)
      INSTALL_PREFIX="${1#*=}"
      ;;
    --install-prefix)
      shift
      [[ $# -gt 0 ]] || die "--install-prefix requires a value"
      INSTALL_PREFIX="$1"
      ;;
    --llvm-archive=*)
      LLVM_ARCHIVE="${1#*=}"
      ;;
    --llvm-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvm-archive requires a value"
      LLVM_ARCHIVE="$1"
      ;;
    --clang-root=*)
      CLANG_ROOT="${1#*=}"
      ;;
    --clang-root)
      shift
      [[ $# -gt 0 ]] || die "--clang-root requires a value"
      CLANG_ROOT="$1"
      ;;
    --ninja-archive=*)
      NINJA_ARCHIVE="${1#*=}"
      ;;
    --ninja-archive)
      shift
      [[ $# -gt 0 ]] || die "--ninja-archive requires a value"
      NINJA_ARCHIVE="$1"
      ;;
    --bison-archive=*)
      BISON_ARCHIVE="${1#*=}"
      ;;
    --bison-archive)
      shift
      [[ $# -gt 0 ]] || die "--bison-archive requires a value"
      BISON_ARCHIVE="$1"
      ;;
    --flex-archive=*)
      FLEX_ARCHIVE="${1#*=}"
      ;;
    --flex-archive)
      shift
      [[ $# -gt 0 ]] || die "--flex-archive requires a value"
      FLEX_ARCHIVE="$1"
      ;;
    --ninja-source-dir=*)
      NINJA_SOURCE_DIR="${1#*=}"
      ;;
    --ninja-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--ninja-source-dir requires a value"
      NINJA_SOURCE_DIR="$1"
      ;;
    --bison-source-dir=*)
      BISON_SOURCE_DIR="${1#*=}"
      ;;
    --bison-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--bison-source-dir requires a value"
      BISON_SOURCE_DIR="$1"
      ;;
    --flex-source-dir=*)
      FLEX_SOURCE_DIR="${1#*=}"
      ;;
    --flex-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--flex-source-dir requires a value"
      FLEX_SOURCE_DIR="$1"
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
  DIST_DIR="${PROJECT_ROOT}/dist/stage_python/${ARCH}"
fi

if [[ -z "$INPUT_ROOTFS_DIR" ]]; then
  INPUT_ROOTFS_DIR="${PROJECT_ROOT}/dist/stage1/${ARCH}"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  echo "Cleaning build directory: ${BUILD_DIR}"
  cmake -E rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"

echo "Configuring stage_python for arch=${ARCH} target=${TARGET_TRIPLE}"

cmake_args=(
  -S "${ROOT_DIR}"
  -B "${BUILD_DIR}"
  -DSTAGE_PYTHON_TARGET_TRIPLE="${TARGET_TRIPLE}"
  -DSTAGE_PYTHON_INPUT_ROOTFS_DIR="${INPUT_ROOTFS_DIR}"
  -DSTAGE_PYTHON_INSTALL_PREFIX="${INSTALL_PREFIX}"
)

if [[ -n "$JOBS" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_JOBS=${JOBS}")
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  cmake_args+=("-DCMAKE_VERBOSE_MAKEFILE=ON")
fi

if [[ -n "$LLVM_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_LLVM_ARCHIVE=${LLVM_ARCHIVE}")
fi

if [[ -n "$CLANG_ROOT" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_CLANG_ROOT=${CLANG_ROOT}")
fi

if [[ -n "$NINJA_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_NINJA_ARCHIVE=${NINJA_ARCHIVE}")
fi

if [[ -n "$BISON_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_BISON_ARCHIVE=${BISON_ARCHIVE}")
fi

if [[ -n "$FLEX_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_FLEX_ARCHIVE=${FLEX_ARCHIVE}")
fi

if [[ -n "$NINJA_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_NINJA_SOURCE_DIR=${NINJA_SOURCE_DIR}")
fi

if [[ -n "$BISON_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_BISON_SOURCE_DIR=${BISON_SOURCE_DIR}")
fi

if [[ -n "$FLEX_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_FLEX_SOURCE_DIR=${FLEX_SOURCE_DIR}")
fi

if [[ ${#CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
  cmake_args+=("${CMAKE_EXTRA_ARGS[@]}")
fi

cmake "${cmake_args[@]}"

echo "Building stage_python rootfs"

build_args=(
  --build "${BUILD_DIR}"
  --target stage-python-rootfs
)

if [[ -n "$JOBS" ]]; then
  build_args+=(--parallel "$JOBS")
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  build_args+=(--verbose)
fi

cmake "${build_args[@]}"

ROOTFS_OUT="${BUILD_DIR}/out/${TARGET_TRIPLE}/rootfs"
[[ -d "$ROOTFS_OUT" ]] || die "expected stage_python rootfs not found: $ROOTFS_OUT"

echo "Copying final rootfs to ${DIST_DIR}"
copy_tree_clean "$ROOTFS_OUT" "$DIST_DIR"

echo "stage_python rootfs is ready at ${DIST_DIR}"
