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
  ./packages/gdal/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>                  GDAL target, see list above
  --arch=<target>                    Alias for --target
  --gdal-version=<ver>               GDAL version (default: 3.13.1)
  --postgresql-deps-archive=<tar>    postgresql_dependencies archive to use as base prefix
  --postgresql-deps-dir=<dir>        Already extracted postgresql_dependencies prefix
  --image-archive=<tar>              image archive to overlay on the base prefix
  --image-dir=<dir>                  Already extracted image prefix
  --llvm-version=<ver>               Bootstrap LLVM toolchain version (default: 18.1.8)
  --image=<image>                    Build image for every target
                                     (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                         Parallel build jobs inside container (default: 4)
  --package-name=<name>              Override the top-level directory and tarball stem
  --pull                             Pull the selected build image before building
  --clean                            Remove this target's build and output directories first
  -h, --help                         Show this help

Outputs:
  packages/gdal/build/dist/gdal-<version>-<triple>.tar.xz
EOF
}

find_local_postgresql_deps_archive() {
  local archive_name=""
  local archive_path=""

  for archive_name in \
      "postgresql_dependencies-18-${PACKAGE_TRIPLE}.tar.xz" \
      "postgresql_dependencies-${PACKAGE_TRIPLE}.tar.xz"; do
    archive_path="${PROJECT_ROOT}/packages/postgresql_dependencies/build/dist/${archive_name}"
    if [[ -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi
  done

  archive_path="$(
    find "${PROJECT_ROOT}/tmp" \
      \( -name "postgresql_dependencies-18-${PACKAGE_TRIPLE}.tar.xz" \
         -o -name "postgresql_dependencies-${PACKAGE_TRIPLE}.tar.xz" \) \
      -type f 2>/dev/null \
      | sort -r \
      | head -n 1
  )"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  return 1
}

find_local_image_archive() {
  local archive_name="image-${PACKAGE_TRIPLE}.tar.xz"
  local archive_path="${PROJECT_ROOT}/packages/image/build/dist/${archive_name}"

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

  [[ -f "${dir}/README.postgresql-dependencies" ]] || die "missing postgresql_dependencies marker: ${dir}/README.postgresql-dependencies"
  [[ -f "${dir}/README.image" ]] || die "missing image marker: ${dir}/README.image"
  [[ -d "${dir}/include" ]] || die "missing include directory: ${dir}/include"
  [[ -d "${dir}/lib" ]] || die "missing lib directory: ${dir}/lib"
}

TARGET=""
GDAL_VERSION="3.13.1"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
POSTGRESQL_DEPS_ARCHIVE=""
POSTGRESQL_DEPS_DIR=""
IMAGE_ARCHIVE=""
IMAGE_DIR=""
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
    --gdal-version)
      shift
      [[ $# -gt 0 ]] || die "--gdal-version requires a value"
      GDAL_VERSION="$1"
      ;;
    --postgresql-deps-archive=*|--dependency-archive=*) POSTGRESQL_DEPS_ARCHIVE="${1#*=}" ;;
    --postgresql-deps-archive|--dependency-archive)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      POSTGRESQL_DEPS_ARCHIVE="$1"
      ;;
    --postgresql-deps-dir=*|--dependency-dir=*) POSTGRESQL_DEPS_DIR="${1#*=}" ;;
    --postgresql-deps-dir|--dependency-dir)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      POSTGRESQL_DEPS_DIR="$1"
      ;;
    --image-archive=*) IMAGE_ARCHIVE="${1#*=}" ;;
    --image-archive)
      shift
      [[ $# -gt 0 ]] || die "--image-archive requires a value"
      IMAGE_ARCHIVE="$1"
      ;;
    --image-dir=*) IMAGE_DIR="${1#*=}" ;;
    --image-dir)
      shift
      [[ $# -gt 0 ]] || die "--image-dir requires a value"
      IMAGE_DIR="$1"
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
resolve_target "$TARGET" "GDAL target"

if [[ -n "$POSTGRESQL_DEPS_ARCHIVE" && -n "$POSTGRESQL_DEPS_DIR" ]]; then
  die "--postgresql-deps-archive and --postgresql-deps-dir are mutually exclusive"
fi
if [[ -n "$IMAGE_ARCHIVE" && -n "$IMAGE_DIR" ]]; then
  die "--image-archive and --image-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="gdal-${GDAL_VERSION}-${PACKAGE_TRIPLE}"
fi

if [[ -z "$POSTGRESQL_DEPS_ARCHIVE" && -z "$POSTGRESQL_DEPS_DIR" ]]; then
  POSTGRESQL_DEPS_ARCHIVE="$(find_local_postgresql_deps_archive)" \
    || die "postgresql_dependencies archive not provided and default archive was not found for ${PACKAGE_TRIPLE}"
fi
if [[ -z "$IMAGE_ARCHIVE" && -z "$IMAGE_DIR" ]]; then
  IMAGE_ARCHIVE="$(find_local_image_archive)" \
    || die "image archive not provided and default archive was not found for ${PACKAGE_TRIPLE}"
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
  echo "-- cleaning GDAL target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
copy_or_extract_prefix "$OUT_DIR" "$POSTGRESQL_DEPS_ARCHIVE" "$POSTGRESQL_DEPS_DIR" \
  "README.postgresql-dependencies" \
  "postgresql_dependencies-18-${PACKAGE_TRIPLE}" \
  "postgresql_dependencies-${PACKAGE_TRIPLE}"
copy_or_extract_prefix "$OUT_DIR" "$IMAGE_ARCHIVE" "$IMAGE_DIR" \
  "README.image" \
  "image-${PACKAGE_TRIPLE}"
validate_input_prefixes "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- GDAL build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- gdal version: ${GDAL_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$POSTGRESQL_DEPS_ARCHIVE" ]]; then
  echo "-- base dependency archive: ${POSTGRESQL_DEPS_ARCHIVE}"
else
  echo "-- base dependency dir: ${POSTGRESQL_DEPS_DIR}"
fi
if [[ -n "$IMAGE_ARCHIVE" ]]; then
  echo "-- image dependency archive: ${IMAGE_ARCHIVE}"
else
  echo "-- image dependency dir: ${IMAGE_DIR}"
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
  -e GDAL_VERSION="$GDAL_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash "/work/mount_root/${CONTAINER_SCRIPT}"

make_host_writable "$PACKAGE_ROOT"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- GDAL archive ready: ${ARCHIVE_PATH}"
