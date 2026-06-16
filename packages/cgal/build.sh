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
  ./packages/cgal/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>            CGAL/SFCGAL target, see list above
  --arch=<target>              Alias for --target
  --boost-version=<ver>        Boost package version (default: 1.84.0)
  --boost-archive=<tar>        Boost package archive to use as base prefix
  --boost-dir=<dir>            Already extracted Boost prefix
  --gmp-version=<ver>          GMP version (default: 6.3.0)
  --mpfr-version=<ver>         MPFR version (default: 4.2.2)
  --cgal-version=<ver>         CGAL version (default: 5.6.3)
  --sfcgal-version=<ver>       SFCGAL version (default: 1.5.2)
  --llvm-version=<ver>         Bootstrap LLVM toolchain version (default: 18.1.8)
  --image=<image>              Build image for every target
                               (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                   Parallel build jobs inside container (default: 4)
  --package-name=<name>        Override the top-level directory and tarball stem
  --pull                       Pull the selected build image before building
  --clean                      Remove this target's build and output directories first
  -h, --help                   Show this help

Outputs:
  packages/cgal/build/dist/cgal-<cgal-version>-sfcgal-<sfcgal-version>-<triple>.tar.xz
EOF
}

find_local_boost_archive() {
  local archive_name="boost-${BOOST_VERSION}-${PACKAGE_TRIPLE}.tar.xz"
  local archive_path="${PROJECT_ROOT}/packages/boost/build/dist/${archive_name}"

  if [[ -f "$archive_path" ]]; then
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

copy_or_extract_boost_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local expected_dir="boost-${BOOST_VERSION}-${PACKAGE_TRIPLE}"
  local tmp_extract="${output_dir}.boost-extract"
  local extracted_dir=""

  rm -rf "$output_dir" "$tmp_extract"
  mkdir -p "$output_dir"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "Boost directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
    return 0
  fi

  [[ -f "$archive_path" ]] || die "Boost archive not found: ${archive_path}"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"
  if [[ -d "${tmp_extract}/${expected_dir}" ]]; then
    extracted_dir="${tmp_extract}/${expected_dir}"
  elif [[ -f "${tmp_extract}/README.boost" ]]; then
    extracted_dir="$tmp_extract"
  else
    die "could not find Boost prefix in archive: ${archive_path}"
  fi
  cp -a "${extracted_dir}/." "$output_dir/"
  rm -rf "$tmp_extract"
}

validate_boost_prefix() {
  local dir="$1"

  [[ -f "${dir}/README.boost" ]] || die "missing Boost marker: ${dir}/README.boost"
  [[ -f "${dir}/include/boost/version.hpp" ]] || die "missing Boost headers"
  [[ -d "${dir}/lib" ]] || die "missing Boost lib directory"
}

TARGET=""
BOOST_VERSION="1.84.0"
BOOST_ARCHIVE=""
BOOST_DIR=""
GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.2"
CGAL_VERSION="5.6.3"
SFCGAL_VERSION="1.5.2"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
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
    --boost-version=*) BOOST_VERSION="${1#*=}" ;;
    --boost-version)
      shift
      [[ $# -gt 0 ]] || die "--boost-version requires a value"
      BOOST_VERSION="$1"
      ;;
    --boost-archive=*) BOOST_ARCHIVE="${1#*=}" ;;
    --boost-archive)
      shift
      [[ $# -gt 0 ]] || die "--boost-archive requires a value"
      BOOST_ARCHIVE="$1"
      ;;
    --boost-dir=*) BOOST_DIR="${1#*=}" ;;
    --boost-dir)
      shift
      [[ $# -gt 0 ]] || die "--boost-dir requires a value"
      BOOST_DIR="$1"
      ;;
    --gmp-version=*) GMP_VERSION="${1#*=}" ;;
    --gmp-version)
      shift
      [[ $# -gt 0 ]] || die "--gmp-version requires a value"
      GMP_VERSION="$1"
      ;;
    --mpfr-version=*) MPFR_VERSION="${1#*=}" ;;
    --mpfr-version)
      shift
      [[ $# -gt 0 ]] || die "--mpfr-version requires a value"
      MPFR_VERSION="$1"
      ;;
    --cgal-version=*) CGAL_VERSION="${1#*=}" ;;
    --cgal-version)
      shift
      [[ $# -gt 0 ]] || die "--cgal-version requires a value"
      CGAL_VERSION="$1"
      ;;
    --sfcgal-version=*) SFCGAL_VERSION="${1#*=}" ;;
    --sfcgal-version)
      shift
      [[ $# -gt 0 ]] || die "--sfcgal-version requires a value"
      SFCGAL_VERSION="$1"
      ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
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
resolve_target "$TARGET" "CGAL/SFCGAL target"

if [[ -n "$BOOST_ARCHIVE" && -n "$BOOST_DIR" ]]; then
  die "--boost-archive and --boost-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="cgal-${CGAL_VERSION}-sfcgal-${SFCGAL_VERSION}-${PACKAGE_TRIPLE}"
fi

if [[ -z "$BOOST_ARCHIVE" && -z "$BOOST_DIR" ]]; then
  BOOST_ARCHIVE="$(find_local_boost_archive)" \
    || die "Boost archive not provided and default archive was not found for ${PACKAGE_TRIPLE}"
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

case "$TARGET_KIND" in
  linux)
    if [[ "$ARCH" == "x86_64" ]]; then
      CONTAINER_SCRIPT="container_linux_native.sh"
    else
      CONTAINER_SCRIPT="container_linux_cross.sh"
    fi
    ;;
  mingw)
    CONTAINER_SCRIPT="container_mingw64.sh"
    ;;
  *)
    die "unsupported target kind: ${TARGET_KIND}"
    ;;
esac

[[ -f "${MOUNT_ROOT}/${CONTAINER_SCRIPT}" ]] || die "missing container script: ${MOUNT_ROOT}/${CONTAINER_SCRIPT}"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning CGAL target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

copy_or_extract_boost_prefix "$OUT_DIR" "$BOOST_ARCHIVE" "$BOOST_DIR"
validate_boost_prefix "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- CGAL/SFCGAL build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- boost version: ${BOOST_VERSION}"
echo "-- cgal version: ${CGAL_VERSION}"
echo "-- sfcgal version: ${SFCGAL_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$BOOST_ARCHIVE" ]]; then
  echo "-- boost archive: ${BOOST_ARCHIVE}"
else
  echo "-- boost dir: ${BOOST_DIR}"
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
  -e BOOST_VERSION="$BOOST_VERSION" \
  -e GMP_VERSION="$GMP_VERSION" \
  -e MPFR_VERSION="$MPFR_VERSION" \
  -e CGAL_VERSION="$CGAL_VERSION" \
  -e SFCGAL_VERSION="$SFCGAL_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash "/work/mount_root/${CONTAINER_SCRIPT}"

make_host_writable "$PACKAGE_ROOT"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- CGAL/SFCGAL archive ready: ${ARCHIVE_PATH}"
