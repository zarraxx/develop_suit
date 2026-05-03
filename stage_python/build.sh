#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage_python/build.sh [options]

Options:
  --clean                      Remove the build directory before configuring
  --jobs=<n>                   Parallel build jobs passed to CMake and Make
  --verbose                    Enable verbose build output
  --build-dir=<path>           Override CMake build directory
  --dist-dir=<path>            Override final output directory (default: <repo>/dist/stage_python)
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

copy_tree_clean() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || die "source directory does not exist: $src"

  cmake -E rm -rf "$dst"
  cmake -E make_directory "$dst"
  cp -a "${src}/." "$dst/"
}

CLEAN=0
JOBS=""
VERBOSE=0
BUILD_DIR=""
DIST_DIR=""
NINJA_ARCHIVE=""
BISON_ARCHIVE=""
FLEX_ARCHIVE=""
NINJA_SOURCE_DIR=""
BISON_SOURCE_DIR=""
FLEX_SOURCE_DIR=""
CMAKE_EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
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

require_command cmake
require_command cp

if [[ -z "$BUILD_DIR" ]]; then
  BUILD_DIR="${ROOT_DIR}/build"
fi

if [[ -z "$DIST_DIR" ]]; then
  DIST_DIR="${PROJECT_ROOT}/dist/stage_python"
fi

if [[ "$CLEAN" -eq 1 ]]; then
  echo "Cleaning build directory: ${BUILD_DIR}"
  cmake -E rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"

echo "Configuring stage_python in ${BUILD_DIR}"

cmake_args=(
  -S "${ROOT_DIR}"
  -B "${BUILD_DIR}"
)

if [[ -n "$JOBS" ]]; then
  cmake_args+=("-DSTAGE_PYTHON_JOBS=${JOBS}")
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  cmake_args+=("-DCMAKE_VERBOSE_MAKEFILE=ON")
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

echo "Building stage_python host tools"

build_args=(
  --build "${BUILD_DIR}"
  --target stage-python-tools
)

if [[ -n "$JOBS" ]]; then
  build_args+=(--parallel "$JOBS")
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  build_args+=(--verbose)
fi

cmake "${build_args[@]}"

INSTALL_OUT="${BUILD_DIR}/out/host"
[[ -d "$INSTALL_OUT" ]] || die "expected install directory not found: $INSTALL_OUT"

echo "Copying final host tools to ${DIST_DIR}"
copy_tree_clean "$INSTALL_OUT" "$DIST_DIR"

echo "stage_python host tools are ready at ${DIST_DIR}"
