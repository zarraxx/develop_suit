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
  ./packages/postgis_dependencies/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>               PostGIS dependency target, see list above
  --arch=<target>                 Alias for --target
  --gdal-version=<ver>            GDAL input package version (default: 3.13.1)
  --cgal-version=<ver>            CGAL input package version (default: 5.6.3)
  --sfcgal-version=<ver>          SFCGAL input package version (default: 1.5.2)
  --libmd-version=<ver>           libmd version (default: 1.2.0)
  --libbsd-version=<ver>          libbsd version (default: 0.12.2)
  --qhull-version=<ver>           Qhull upstream version label (default: 2020.2)
  --protobuf-version=<ver>        protobuf version (default: 21.0)
  --protobuf-c-version=<ver>      protobuf-c version (default: 1.5.2)
  --gdal-archive=<tar>            GDAL package archive to use as base prefix
  --gdal-dir=<dir>                Already extracted GDAL prefix
  --cgal-archive=<tar>            CGAL/SFCGAL package archive to overlay
  --cgal-dir=<dir>                Already extracted CGAL/SFCGAL prefix
  --llvm-version=<ver>            Bootstrap LLVM toolchain version (default: 18.1.8)
  --image=<image>                 Build image for every target
                                  (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                      Parallel build jobs inside container (default: 4)
  --package-name=<name>           Override the top-level directory and tarball stem
  --pull                          Pull the selected build image before building
  --clean                         Remove this target's build and output directories first
  -h, --help                      Show this help

Outputs:
  packages/postgis_dependencies/build/dist/postgis_dependencies-<triple>.tar.xz
EOF
}

find_local_gdal_archive() {
  local archive_name="gdal-${GDAL_VERSION}-${PACKAGE_TRIPLE}.tar.xz"
  local archive_path="${PROJECT_ROOT}/packages/gdal/build/dist/${archive_name}"

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

find_local_cgal_archive() {
  local archive_name="cgal-${CGAL_VERSION}-sfcgal-${SFCGAL_VERSION}-${PACKAGE_TRIPLE}.tar.xz"
  local archive_path="${PROJECT_ROOT}/packages/cgal/build/dist/${archive_name}"

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

copy_or_extract_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local marker_name="$4"
  shift 4
  local expected_dirs=("$@")
  local tmp_extract="${output_dir}.extract"
  local extracted_dir=""
  local expected_dir=""

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "dependency directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
    return 0
  fi

  [[ -f "$archive_path" ]] || die "dependency archive not found: ${archive_path}"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"
  for expected_dir in "${expected_dirs[@]}"; do
    if [[ -d "${tmp_extract}/${expected_dir}" ]]; then
      extracted_dir="${tmp_extract}/${expected_dir}"
      break
    fi
  done
  if [[ -z "$extracted_dir" && -f "${tmp_extract}/${marker_name}" ]]; then
    extracted_dir="$tmp_extract"
  fi
  [[ -n "$extracted_dir" ]] || die "could not find dependency prefix in archive: ${archive_path}"
  cp -a "${extracted_dir}/." "$output_dir/"
  rm -rf "$tmp_extract"
}

validate_input_prefixes() {
  local dir="$1"

  [[ -f "${dir}/README.gdal" ]] || die "missing GDAL marker: ${dir}/README.gdal"
  [[ -f "${dir}/README.cgal" ]] || die "missing CGAL marker: ${dir}/README.cgal"
  [[ -f "${dir}/include/gdal.h" ]] || die "missing GDAL headers"
  [[ -f "${dir}/include/SFCGAL/version.h" ]] || die "missing SFCGAL headers"
  [[ -d "${dir}/lib" ]] || die "missing lib directory: ${dir}/lib"
}

TARGET=""
GDAL_VERSION="3.13.1"
CGAL_VERSION="5.6.3"
SFCGAL_VERSION="1.5.2"
LIBMD_VERSION="1.2.0"
LIBBSD_VERSION="0.12.2"
QHULL_VERSION="2020.2"
PROTOBUF_VERSION="21.0"
PROTOBUF_C_VERSION="1.5.2"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
GDAL_ARCHIVE=""
GDAL_DIR=""
CGAL_ARCHIVE=""
CGAL_DIR=""
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
    --gdal-version=*) GDAL_VERSION="${1#*=}" ;;
    --gdal-version) shift; [[ $# -gt 0 ]] || die "--gdal-version requires a value"; GDAL_VERSION="$1" ;;
    --cgal-version=*) CGAL_VERSION="${1#*=}" ;;
    --cgal-version) shift; [[ $# -gt 0 ]] || die "--cgal-version requires a value"; CGAL_VERSION="$1" ;;
    --sfcgal-version=*) SFCGAL_VERSION="${1#*=}" ;;
    --sfcgal-version) shift; [[ $# -gt 0 ]] || die "--sfcgal-version requires a value"; SFCGAL_VERSION="$1" ;;
    --libmd-version=*) LIBMD_VERSION="${1#*=}" ;;
    --libmd-version) shift; [[ $# -gt 0 ]] || die "--libmd-version requires a value"; LIBMD_VERSION="$1" ;;
    --libbsd-version=*) LIBBSD_VERSION="${1#*=}" ;;
    --libbsd-version) shift; [[ $# -gt 0 ]] || die "--libbsd-version requires a value"; LIBBSD_VERSION="$1" ;;
    --qhull-version=*) QHULL_VERSION="${1#*=}" ;;
    --qhull-version) shift; [[ $# -gt 0 ]] || die "--qhull-version requires a value"; QHULL_VERSION="$1" ;;
    --protobuf-version=*) PROTOBUF_VERSION="${1#*=}" ;;
    --protobuf-version) shift; [[ $# -gt 0 ]] || die "--protobuf-version requires a value"; PROTOBUF_VERSION="$1" ;;
    --protobuf-c-version=*) PROTOBUF_C_VERSION="${1#*=}" ;;
    --protobuf-c-version) shift; [[ $# -gt 0 ]] || die "--protobuf-c-version requires a value"; PROTOBUF_C_VERSION="$1" ;;
    --gdal-archive=*) GDAL_ARCHIVE="${1#*=}" ;;
    --gdal-archive) shift; [[ $# -gt 0 ]] || die "--gdal-archive requires a value"; GDAL_ARCHIVE="$1" ;;
    --gdal-dir=*) GDAL_DIR="${1#*=}" ;;
    --gdal-dir) shift; [[ $# -gt 0 ]] || die "--gdal-dir requires a value"; GDAL_DIR="$1" ;;
    --cgal-archive=*) CGAL_ARCHIVE="${1#*=}" ;;
    --cgal-archive) shift; [[ $# -gt 0 ]] || die "--cgal-archive requires a value"; CGAL_ARCHIVE="$1" ;;
    --cgal-dir=*) CGAL_DIR="${1#*=}" ;;
    --cgal-dir) shift; [[ $# -gt 0 ]] || die "--cgal-dir requires a value"; CGAL_DIR="$1" ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version) shift; [[ $# -gt 0 ]] || die "--llvm-version requires a value"; LLVM_VERSION="$1" ;;
    --image=*|--linux-image=*|--mingw-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image|--mingw-image)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      BUILD_IMAGE="$1"
      ;;
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
resolve_target "$TARGET" "PostGIS dependency target"

if [[ -n "$GDAL_ARCHIVE" && -n "$GDAL_DIR" ]]; then
  die "--gdal-archive and --gdal-dir are mutually exclusive"
fi
if [[ -n "$CGAL_ARCHIVE" && -n "$CGAL_DIR" ]]; then
  die "--cgal-archive and --cgal-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="postgis_dependencies-${PACKAGE_TRIPLE}"
fi

if [[ -z "$GDAL_ARCHIVE" && -z "$GDAL_DIR" ]]; then
  GDAL_ARCHIVE="$(find_local_gdal_archive)" \
    || die "GDAL archive not provided and default archive was not found for ${PACKAGE_TRIPLE}"
fi
if [[ -z "$CGAL_ARCHIVE" && -z "$CGAL_DIR" ]]; then
  CGAL_ARCHIVE="$(find_local_cgal_archive)" \
    || die "CGAL archive not provided and default archive was not found for ${PACKAGE_TRIPLE}"
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
  echo "-- cleaning PostGIS dependency target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
copy_or_extract_prefix "$OUT_DIR" "$GDAL_ARCHIVE" "$GDAL_DIR" \
  "README.gdal" \
  "gdal-${GDAL_VERSION}-${PACKAGE_TRIPLE}"
copy_or_extract_prefix "$OUT_DIR" "$CGAL_ARCHIVE" "$CGAL_DIR" \
  "README.cgal" \
  "cgal-${CGAL_VERSION}-sfcgal-${SFCGAL_VERSION}-${PACKAGE_TRIPLE}"
validate_input_prefixes "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- PostGIS dependency build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$GDAL_ARCHIVE" ]]; then
  echo "-- GDAL archive: ${GDAL_ARCHIVE}"
else
  echo "-- GDAL dir: ${GDAL_DIR}"
fi
if [[ -n "$CGAL_ARCHIVE" ]]; then
  echo "-- CGAL archive: ${CGAL_ARCHIVE}"
else
  echo "-- CGAL dir: ${CGAL_DIR}"
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
  -e LIBMD_VERSION="$LIBMD_VERSION" \
  -e LIBBSD_VERSION="$LIBBSD_VERSION" \
  -e QHULL_VERSION="$QHULL_VERSION" \
  -e PROTOBUF_VERSION="$PROTOBUF_VERSION" \
  -e PROTOBUF_C_VERSION="$PROTOBUF_C_VERSION" \
  -e GDAL_VERSION="$GDAL_VERSION" \
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
chmod 664 "$ARCHIVE_PATH"

echo "-- PostGIS dependency archive ready: ${ARCHIVE_PATH}"
