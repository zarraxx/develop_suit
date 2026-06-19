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
  ./packages/fdw_dependencies/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>               FDW dependency target, see list above
  --arch=<target>                 Alias for --target
  --unixodbc-version=<ver>        unixODBC version, Linux only (default: 2.3.14)
  --freetds-version=<ver>         FreeTDS version (default: 1.5.16)
  --mariadb-version=<ver>         MariaDB Connector/C version (default: 3.4.9)
  --hiredis-version=<ver>         hiredis version (default: 1.4.0)
  --mongo-c-driver-version=<ver>  MongoDB C Driver version (default: 1.30.8)
  --postgresql-deps-archive=<tar> postgresql_dependencies archive to use as base prefix
  --postgresql-deps-dir=<dir>     Already extracted postgresql_dependencies prefix
  --llvm-version=<ver>            Bootstrap LLVM toolchain version (default: 18.1.8)
  --image=<image>                 Build image
                                  (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                      Parallel build jobs inside container (default: 4)
  --package-name=<name>           Override the top-level directory and tarball stem
  --pull                          Pull the selected build image before building
  --clean                         Remove this target's build and output directories first
  -h, --help                      Show this help

Outputs:
  packages/fdw_dependencies/build/dist/fdw_dependencies-<triple>.tar.xz
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

validate_input_prefix() {
  local dir="$1"

  [[ -f "${dir}/README.postgresql-dependencies" ]] || die "missing postgresql_dependencies marker: ${dir}/README.postgresql-dependencies"
  [[ -d "${dir}/include" ]] || die "missing include directory: ${dir}/include"
  [[ -d "${dir}/lib" ]] || die "missing lib directory: ${dir}/lib"
}

TARGET=""
UNIXODBC_VERSION="2.3.14"
FREETDS_VERSION="1.5.16"
MARIADB_VERSION="3.4.9"
HIREDIS_VERSION="1.4.0"
MONGO_C_DRIVER_VERSION="1.30.8"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
POSTGRESQL_DEPS_ARCHIVE=""
POSTGRESQL_DEPS_DIR=""
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
    --unixodbc-version=*) UNIXODBC_VERSION="${1#*=}" ;;
    --unixodbc-version) shift; [[ $# -gt 0 ]] || die "--unixodbc-version requires a value"; UNIXODBC_VERSION="$1" ;;
    --freetds-version=*) FREETDS_VERSION="${1#*=}" ;;
    --freetds-version) shift; [[ $# -gt 0 ]] || die "--freetds-version requires a value"; FREETDS_VERSION="$1" ;;
    --mariadb-version=*|--mysql-version=*) MARIADB_VERSION="${1#*=}" ;;
    --mariadb-version|--mysql-version)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      MARIADB_VERSION="$1"
      ;;
    --hiredis-version=*) HIREDIS_VERSION="${1#*=}" ;;
    --hiredis-version) shift; [[ $# -gt 0 ]] || die "--hiredis-version requires a value"; HIREDIS_VERSION="$1" ;;
    --mongo-c-driver-version=*|--mongodb-version=*) MONGO_C_DRIVER_VERSION="${1#*=}" ;;
    --mongo-c-driver-version|--mongodb-version)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      MONGO_C_DRIVER_VERSION="$1"
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
resolve_target "$TARGET" "FDW dependency target"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "fdw_dependencies supports x86_64/aarch64/riscv64/loongarch64 Linux and x86_64 MinGW" ;;
esac

if [[ -n "$POSTGRESQL_DEPS_ARCHIVE" && -n "$POSTGRESQL_DEPS_DIR" ]]; then
  die "--postgresql-deps-archive and --postgresql-deps-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="fdw_dependencies-${PACKAGE_TRIPLE}"
fi

if [[ -z "$POSTGRESQL_DEPS_ARCHIVE" && -z "$POSTGRESQL_DEPS_DIR" ]]; then
  POSTGRESQL_DEPS_ARCHIVE="$(find_local_postgresql_deps_archive || true)"
fi
[[ -n "$POSTGRESQL_DEPS_ARCHIVE" || -n "$POSTGRESQL_DEPS_DIR" ]] \
  || die "postgresql_dependencies input is required; pass --postgresql-deps-archive or --postgresql-deps-dir"

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

[[ -f "${MOUNT_ROOT}/container_fdw_dependencies.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_fdw_dependencies.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning FDW dependency target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

copy_or_extract_prefix "$OUT_DIR" "$POSTGRESQL_DEPS_ARCHIVE" "$POSTGRESQL_DEPS_DIR" \
  "README.postgresql-dependencies" \
  "postgresql_dependencies-18-${PACKAGE_TRIPLE}" \
  "postgresql_dependencies-${PACKAGE_TRIPLE}" \
  "$PACKAGE_NAME"
validate_input_prefix "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- FDW dependency build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$POSTGRESQL_DEPS_DIR" ]]; then
  echo "-- postgresql_dependencies dir: ${POSTGRESQL_DEPS_DIR}"
else
  echo "-- postgresql_dependencies archive: ${POSTGRESQL_DEPS_ARCHIVE}"
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
  -e UNIXODBC_VERSION="$UNIXODBC_VERSION" \
  -e FREETDS_VERSION="$FREETDS_VERSION" \
  -e MARIADB_VERSION="$MARIADB_VERSION" \
  -e HIREDIS_VERSION="$HIREDIS_VERSION" \
  -e MONGO_C_DRIVER_VERSION="$MONGO_C_DRIVER_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_fdw_dependencies.sh

make_host_writable "$PACKAGE_ROOT"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"
chmod 664 "$ARCHIVE_PATH"

echo "-- FDW dependency archive ready: ${ARCHIVE_PATH}"
