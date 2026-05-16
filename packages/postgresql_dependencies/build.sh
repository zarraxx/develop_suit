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
  ./packages/postgresql_dependencies/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>             Dependency target
  --arch=<target>               Alias for --target
  --llvm-version=<ver>          Bootstrap LLVM toolchain version (default: 18.1.8)
  --python-deps-archive=<tar>   python_dependencies archive to use as base prefix
  --python-deps-dir=<dir>       Already extracted python_dependencies prefix
  --image=<image>               Build image for every target
                                (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                    Parallel build jobs inside container (default: 4)
  --package-name=<name>         Override top-level directory and tarball stem
  --pull                        Pull the selected build image before building
  --clean                       Remove this target's build and output directories first
  -h, --help                    Show this help

Outputs:
  packages/postgresql_dependencies/build/dist/postgresql_dependencies-<triple>.tar.xz
EOF
}

find_local_python_deps_archive() {
  local archive_name="python_dependencies-${PACKAGE_TRIPLE}.tar.xz"
  local archive_path=""

  archive_path="${PROJECT_ROOT}/packages/python_dependencies/build/dist/${archive_name}"
  if [[ -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  archive_name="pyhton_dependencies-3-${PACKAGE_TRIPLE}.tar.xz"
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

copy_or_extract_base_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local package_dir="python_dependencies-${PACKAGE_TRIPLE}"
  local release_package_dir="pyhton_dependencies-3-${PACKAGE_TRIPLE}"
  local tmp_extract="${output_dir}.base-extract"
  local extracted_dir=""

  rm -rf "$output_dir" "$tmp_extract"
  mkdir -p "$output_dir"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "python_dependencies directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
  else
    [[ -f "$archive_path" ]] || die "python_dependencies archive not found: ${archive_path}"
    mkdir -p "$tmp_extract"
    tar -xf "$archive_path" -C "$tmp_extract"
    if [[ -d "${tmp_extract}/${package_dir}" ]]; then
      extracted_dir="${tmp_extract}/${package_dir}"
    elif [[ -d "${tmp_extract}/${release_package_dir}" ]]; then
      extracted_dir="${tmp_extract}/${release_package_dir}"
    elif [[ -f "${tmp_extract}/README.python-dependencies" ]]; then
      extracted_dir="$tmp_extract"
    else
      die "could not find python_dependencies prefix in archive: ${archive_path}"
    fi
    cp -a "${extracted_dir}/." "$output_dir/"
    rm -rf "$tmp_extract"
  fi
}

validate_base_prefix() {
  local dir="$1"

  [[ -d "$dir" ]] || die "base prefix not found: ${dir}"
  [[ -f "${dir}/README.python-dependencies" ]] || die "missing python_dependencies marker: ${dir}/README.python-dependencies"
  [[ -d "${dir}/include" ]] || die "missing base include directory: ${dir}/include"
  [[ -d "${dir}/lib" ]] || die "missing base lib directory: ${dir}/lib"
}

TARGET=""
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
PYTHON_DEPS_ARCHIVE=""
PYTHON_DEPS_DIR=""
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    target=*|arch=*) TARGET="${1#*=}" ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --python-deps-archive=*|--dependency-archive=*) PYTHON_DEPS_ARCHIVE="${1#*=}" ;;
    --python-deps-archive|--dependency-archive)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      PYTHON_DEPS_ARCHIVE="$1"
      ;;
    --python-deps-dir=*|--dependency-dir=*) PYTHON_DEPS_DIR="${1#*=}" ;;
    --python-deps-dir|--dependency-dir)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      PYTHON_DEPS_DIR="$1"
      ;;
    --image=*|--linux-image=*|--mingw-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image|--mingw-image)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      BUILD_IMAGE="$1"
      ;;
    --jobs=*) JOBS="${1#*=}" ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --package-name=*) PACKAGE_NAME="${1#*=}" ;;
    --package-name)
      shift
      [[ $# -gt 0 ]] || die "--package-name requires a value"
      PACKAGE_NAME="$1"
      ;;
    --pull) PULL=1 ;;
    --clean) CLEAN=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "PostgreSQL dependency target"

if [[ -n "$PYTHON_DEPS_ARCHIVE" && -n "$PYTHON_DEPS_DIR" ]]; then
  die "--python-deps-archive and --python-deps-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="postgresql_dependencies-${PACKAGE_TRIPLE}"
fi

if [[ -z "$PYTHON_DEPS_ARCHIVE" && -z "$PYTHON_DEPS_DIR" ]]; then
  PYTHON_DEPS_ARCHIVE="$(find_local_python_deps_archive)" \
    || die "python_dependencies archive not provided and default archive was not found for ${PACKAGE_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_postgresql_dep.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_postgresql_dep.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning PostgreSQL dependencies target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

copy_or_extract_base_prefix "$OUT_DIR" "$PYTHON_DEPS_ARCHIVE" "$PYTHON_DEPS_DIR"
validate_base_prefix "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- PostgreSQL dependencies build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$PYTHON_DEPS_ARCHIVE" ]]; then
  echo "-- base dependency archive: ${PYTHON_DEPS_ARCHIVE}"
else
  echo "-- base dependency dir: ${PYTHON_DEPS_DIR}"
fi

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
  /bin/bash /work/mount_root/container_postgresql_dep.sh

make_host_writable "$PACKAGE_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- PostgreSQL dependency archive ready: ${ARCHIVE_PATH}"
