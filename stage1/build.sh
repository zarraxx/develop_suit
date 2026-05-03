#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage1/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>                Target arch: x86_64, aarch64, riscv64, loongarch64
  --clean                      Remove the per-arch build directory before configuring
  --jobs=<n>                   Parallel build jobs passed to CMake and make
  --build-dir=<path>           Override per-arch CMake build directory
  --dist-dir=<path>            Override final output directory (default: <repo>/dist/stage1/<arch>)
  --input-rootfs-dir=<path>    Override input rootfs directory (default: <repo>/dist/sysroot/<arch>)
  --install-prefix=<path>      Install prefix inside the target rootfs (default: /usr)
  --llvm-archive=<path>        Override LLVM archive path instead of auto-downloading
  --clang-root=<path>          Use a pre-extracted clang root
  --make-archive=<path>        Override GNU make archive path
  --m4-archive=<path>          Override GNU m4 archive path
  --autoconf-archive=<path>    Override autoconf archive path
  --automake-archive=<path>    Override automake archive path
  --libtool-archive=<path>     Override GNU libtool archive path
  --pkg-config-archive=<path>  Override pkgconf archive path
  --patchelf-archive=<path>    Override patchelf archive path
  --curl-archive=<path>        Override curl archive path
  --make-source-dir=<path>     Use a pre-extracted GNU make source tree
  --m4-source-dir=<path>       Use a pre-extracted GNU m4 source tree
  --autoconf-source-dir=<path> Use a pre-extracted autoconf source tree
  --automake-source-dir=<path> Use a pre-extracted automake source tree
  --libtool-source-dir=<path>  Use a pre-extracted GNU libtool source tree
  --pkg-config-source-dir=<path>
                               Use a pre-extracted pkgconf source tree
  --patchelf-source-dir=<path> Use a pre-extracted patchelf source tree
  --curl-source-dir=<path>     Use a pre-extracted curl source tree
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
BUILD_DIR=""
DIST_DIR=""
INPUT_ROOTFS_DIR=""
INSTALL_PREFIX="/usr"
LLVM_ARCHIVE=""
CLANG_ROOT=""
MAKE_ARCHIVE=""
M4_ARCHIVE=""
AUTOCONF_ARCHIVE=""
AUTOMAKE_ARCHIVE=""
LIBTOOL_ARCHIVE=""
PKG_CONFIG_ARCHIVE=""
PATCHELF_ARCHIVE=""
CURL_ARCHIVE=""
MAKE_SOURCE_DIR=""
M4_SOURCE_DIR=""
AUTOCONF_SOURCE_DIR=""
AUTOMAKE_SOURCE_DIR=""
LIBTOOL_SOURCE_DIR=""
PKG_CONFIG_SOURCE_DIR=""
PATCHELF_SOURCE_DIR=""
CURL_SOURCE_DIR=""
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
    --make-archive=*)
      MAKE_ARCHIVE="${1#*=}"
      ;;
    --make-archive)
      shift
      [[ $# -gt 0 ]] || die "--make-archive requires a value"
      MAKE_ARCHIVE="$1"
      ;;
    --m4-archive=*)
      M4_ARCHIVE="${1#*=}"
      ;;
    --m4-archive)
      shift
      [[ $# -gt 0 ]] || die "--m4-archive requires a value"
      M4_ARCHIVE="$1"
      ;;
    --autoconf-archive=*)
      AUTOCONF_ARCHIVE="${1#*=}"
      ;;
    --autoconf-archive)
      shift
      [[ $# -gt 0 ]] || die "--autoconf-archive requires a value"
      AUTOCONF_ARCHIVE="$1"
      ;;
    --automake-archive=*)
      AUTOMAKE_ARCHIVE="${1#*=}"
      ;;
    --automake-archive)
      shift
      [[ $# -gt 0 ]] || die "--automake-archive requires a value"
      AUTOMAKE_ARCHIVE="$1"
      ;;
    --libtool-archive=*)
      LIBTOOL_ARCHIVE="${1#*=}"
      ;;
    --libtool-archive)
      shift
      [[ $# -gt 0 ]] || die "--libtool-archive requires a value"
      LIBTOOL_ARCHIVE="$1"
      ;;
    --pkg-config-archive=*)
      PKG_CONFIG_ARCHIVE="${1#*=}"
      ;;
    --pkg-config-archive)
      shift
      [[ $# -gt 0 ]] || die "--pkg-config-archive requires a value"
      PKG_CONFIG_ARCHIVE="$1"
      ;;
    --patchelf-archive=*)
      PATCHELF_ARCHIVE="${1#*=}"
      ;;
    --patchelf-archive)
      shift
      [[ $# -gt 0 ]] || die "--patchelf-archive requires a value"
      PATCHELF_ARCHIVE="$1"
      ;;
    --curl-archive=*)
      CURL_ARCHIVE="${1#*=}"
      ;;
    --curl-archive)
      shift
      [[ $# -gt 0 ]] || die "--curl-archive requires a value"
      CURL_ARCHIVE="$1"
      ;;
    --make-source-dir=*)
      MAKE_SOURCE_DIR="${1#*=}"
      ;;
    --make-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--make-source-dir requires a value"
      MAKE_SOURCE_DIR="$1"
      ;;
    --m4-source-dir=*)
      M4_SOURCE_DIR="${1#*=}"
      ;;
    --m4-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--m4-source-dir requires a value"
      M4_SOURCE_DIR="$1"
      ;;
    --autoconf-source-dir=*)
      AUTOCONF_SOURCE_DIR="${1#*=}"
      ;;
    --autoconf-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--autoconf-source-dir requires a value"
      AUTOCONF_SOURCE_DIR="$1"
      ;;
    --automake-source-dir=*)
      AUTOMAKE_SOURCE_DIR="${1#*=}"
      ;;
    --automake-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--automake-source-dir requires a value"
      AUTOMAKE_SOURCE_DIR="$1"
      ;;
    --libtool-source-dir=*)
      LIBTOOL_SOURCE_DIR="${1#*=}"
      ;;
    --libtool-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--libtool-source-dir requires a value"
      LIBTOOL_SOURCE_DIR="$1"
      ;;
    --pkg-config-source-dir=*)
      PKG_CONFIG_SOURCE_DIR="${1#*=}"
      ;;
    --pkg-config-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--pkg-config-source-dir requires a value"
      PKG_CONFIG_SOURCE_DIR="$1"
      ;;
    --patchelf-source-dir=*)
      PATCHELF_SOURCE_DIR="${1#*=}"
      ;;
    --patchelf-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--patchelf-source-dir requires a value"
      PATCHELF_SOURCE_DIR="$1"
      ;;
    --curl-source-dir=*)
      CURL_SOURCE_DIR="${1#*=}"
      ;;
    --curl-source-dir)
      shift
      [[ $# -gt 0 ]] || die "--curl-source-dir requires a value"
      CURL_SOURCE_DIR="$1"
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
  DIST_DIR="${PROJECT_ROOT}/dist/stage1/${ARCH}"
fi

if [[ -z "$INPUT_ROOTFS_DIR" ]]; then
  INPUT_ROOTFS_DIR="${PROJECT_ROOT}/dist/sysroot/${ARCH}"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  echo "Cleaning build directory: ${BUILD_DIR}"
  cmake -E rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"

echo "Configuring stage1 for arch=${ARCH} target=${TARGET_TRIPLE}"

cmake_args=(
  -S "${ROOT_DIR}"
  -B "${BUILD_DIR}"
  -DSTAGE1_TARGET_TRIPLE="${TARGET_TRIPLE}"
  -DSTAGE1_INPUT_ROOTFS_DIR="${INPUT_ROOTFS_DIR}"
  -DSTAGE1_INSTALL_PREFIX="${INSTALL_PREFIX}"
)

if [[ -n "$JOBS" ]]; then
  cmake_args+=("-DSTAGE1_JOBS=${JOBS}")
fi

if [[ -n "$LLVM_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_LLVM_ARCHIVE=${LLVM_ARCHIVE}")
fi

if [[ -n "$CLANG_ROOT" ]]; then
  cmake_args+=("-DSTAGE1_CLANG_ROOT=${CLANG_ROOT}")
fi

if [[ -n "$MAKE_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_MAKE_ARCHIVE=${MAKE_ARCHIVE}")
fi

if [[ -n "$M4_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_M4_ARCHIVE=${M4_ARCHIVE}")
fi

if [[ -n "$AUTOCONF_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_AUTOCONF_ARCHIVE=${AUTOCONF_ARCHIVE}")
fi

if [[ -n "$AUTOMAKE_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_AUTOMAKE_ARCHIVE=${AUTOMAKE_ARCHIVE}")
fi

if [[ -n "$LIBTOOL_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_LIBTOOL_ARCHIVE=${LIBTOOL_ARCHIVE}")
fi

if [[ -n "$PKG_CONFIG_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_PKGCONF_ARCHIVE=${PKG_CONFIG_ARCHIVE}")
fi

if [[ -n "$PATCHELF_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_PATCHELF_ARCHIVE=${PATCHELF_ARCHIVE}")
fi

if [[ -n "$CURL_ARCHIVE" ]]; then
  cmake_args+=("-DSTAGE1_CURL_ARCHIVE=${CURL_ARCHIVE}")
fi

if [[ -n "$MAKE_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_MAKE_SOURCE_DIR=${MAKE_SOURCE_DIR}")
fi

if [[ -n "$M4_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_M4_SOURCE_DIR=${M4_SOURCE_DIR}")
fi

if [[ -n "$AUTOCONF_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_AUTOCONF_SOURCE_DIR=${AUTOCONF_SOURCE_DIR}")
fi

if [[ -n "$AUTOMAKE_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_AUTOMAKE_SOURCE_DIR=${AUTOMAKE_SOURCE_DIR}")
fi

if [[ -n "$LIBTOOL_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_LIBTOOL_SOURCE_DIR=${LIBTOOL_SOURCE_DIR}")
fi

if [[ -n "$PKG_CONFIG_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_PKGCONF_SOURCE_DIR=${PKG_CONFIG_SOURCE_DIR}")
fi

if [[ -n "$PATCHELF_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_PATCHELF_SOURCE_DIR=${PATCHELF_SOURCE_DIR}")
fi

if [[ -n "$CURL_SOURCE_DIR" ]]; then
  cmake_args+=("-DSTAGE1_CURL_SOURCE_DIR=${CURL_SOURCE_DIR}")
fi

if [[ ${#CMAKE_EXTRA_ARGS[@]} -gt 0 ]]; then
  cmake_args+=("${CMAKE_EXTRA_ARGS[@]}")
fi

cmake "${cmake_args[@]}"

echo "Building stage1 rootfs"

build_args=(
  --build "${BUILD_DIR}"
  --target stage1-rootfs
)

if [[ -n "$JOBS" ]]; then
  build_args+=(--parallel "$JOBS")
fi

cmake "${build_args[@]}"

ROOTFS_OUT="${BUILD_DIR}/out/${TARGET_TRIPLE}/rootfs"
[[ -d "$ROOTFS_OUT" ]] || die "expected stage1 rootfs not found: $ROOTFS_OUT"

echo "Copying final rootfs to ${DIST_DIR}"
copy_tree_clean "$ROOTFS_OUT" "$DIST_DIR"

echo "Stage1 rootfs is ready at ${DIST_DIR}"
