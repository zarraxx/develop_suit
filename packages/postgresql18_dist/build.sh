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
  ./packages/postgresql18_dist/build.sh --target=x86_64 [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>                     Distribution target, see list above
  --arch=<target>                       Alias for --target
  --postgresql-version=<ver>            PostgreSQL package version (default: 18.4)
  --postgis-deps-version=<label>        PostGIS dependency release label
  --groonga-version=<ver>               Groonga package version (default: 16.0.5)
  --v8-version=<ver>                    V8 package version (default: 11.6.189.4)
  --postgresql-archive=<tar>            Base PostgreSQL package archive
  --postgis-deps-archive=<tar>          PostGIS dependency package archive
  --groonga-archive=<tar>               Groonga package archive
  --fdw-deps-archive=<tar>              FDW dependency package archive
  --v8-archive=<tar>                    V8 package archive
  --oracle-sdk-archive=<zip>            Oracle Instant Client SDK archive, optional x86_64 Linux/MinGW
  --oracle-basic-archive=<zip>          Oracle Instant Client Basic archive, optional x86_64 Linux/MinGW
  --db2-cli-archive=<archive>           IBM DB2 CLI/ODBC archive, optional x86_64 Linux/MinGW
  --db2-cli-dir=<dir>                   IBM DB2 CLI/ODBC prefix, optional x86_64 Linux/MinGW
  --without-fdw                         Do not build FDW extensions or overlay fdw_dependencies
  --without-oracle-fdw                  Do not build oracle_fdw
  --without-db2-fdw                     Do not build db2_fdw
  --without-pljava                      Do not build PL/Java (currently not implemented)
  --without-tde                         Do not build pg_tde
  --without-repack                      Do not build pg_repack
  --without-plv8                        Do not build plv8 or overlay V8
  --runtime=<docker|podman>             Container runtime override
  --image=<image>                       Build image
  --jobs=<n>                            Parallel build jobs inside container (default: 4)
  --package-name=<name>                 Override output package name
  --pull                                Pull build image before building
  --clean                               Remove target build/output directories first
  -h, --help                            Show this help

Outputs:
  packages/postgresql18_dist/build/dist/postgresql18_dist-<triple>.tar.xz
EOF
}

find_local_archive() {
  local package_dir="$1"
  local pattern="$2"
  local archive_path=""
  local search_dir=""

  archive_path="$(
    find "${PROJECT_ROOT}/packages/${package_dir}/build/dist" \
      -maxdepth 1 -type f -name "$pattern" 2>/dev/null \
      | sort -rV \
      | head -n 1
  )"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  for search_dir in "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/cache"; do
    archive_path="$(
      find "$search_dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null \
        | sort -rV \
        | head -n 1
    )"
    if [[ -n "$archive_path" && -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi
  done

  return 1
}

extract_prefix_archive() {
  local output_dir="$1"
  local archive_path="$2"
  local tmp_extract="${output_dir}.extract"
  local extracted_dir=""

  [[ -f "$archive_path" ]] || die "archive not found: ${archive_path}"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"
  extracted_dir="$(
    find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d -print \
      | sort \
      | head -n 1
  )"
  [[ -n "$extracted_dir" && -d "$extracted_dir" ]] || die "could not find prefix directory in archive: ${archive_path}"
  cp -a "${extracted_dir}/." "$output_dir/"
  rm -rf "$tmp_extract"
}

validate_base_postgresql() {
  local dir="$1"
  local exeext=""

  if [[ "${TARGET_KIND:-linux}" == "mingw" ]]; then
    exeext=".exe"
  fi

  [[ -x "${dir}/bin/pg_config${exeext}" ]] || die "missing pg_config in base PostgreSQL package"
  [[ -x "${dir}/bin/postgres${exeext}" ]] || die "missing postgres in base PostgreSQL package"
  [[ -d "${dir}/include/server" ]] || die "missing PostgreSQL server headers"
  [[ -d "${dir}/lib" ]] || die "missing PostgreSQL lib directory"
}

rewrite_overlay_prefixes() {
  local output_dir="$1"
  local install_prefix="$2"
  local file_path=""

  while IFS= read -r -d '' file_path; do
    case "$file_path" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.h|*.hpp|*.hh|*/Makefile.global|*/Makefile.port|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac

    if grep -IqF "/opt/" "$file_path"; then
      sed -E -i \
        "s#/opt/[^/\"'[:space:]]+-${PACKAGE_TRIPLE}#${install_prefix}#g" \
        "$file_path"
    fi
  done < <(
    find "$output_dir" -type f -print0 2>/dev/null
  )
}

TARGET=""
POSTGRESQL_VERSION="18.4"
POSTGIS_DEPS_VERSION="gdal-3.13.1-cgal-5.6.3-qhull-2020.2"
GROONGA_VERSION="16.0.5"
V8_VERSION="11.6.189.4"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
REQUESTED_RUNTIME=""
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
POSTGRESQL_ARCHIVE=""
POSTGIS_DEPS_ARCHIVE=""
GROONGA_ARCHIVE=""
FDW_DEPS_ARCHIVE=""
V8_ARCHIVE=""
ORACLE_SDK_ARCHIVE=""
ORACLE_BASIC_ARCHIVE=""
DB2_CLI_ARCHIVE=""
DB2_CLI_DIR=""
WITH_FDW=1
WITH_ORACLE_FDW=1
WITH_DB2_FDW=1
WITH_PLJAVA=0
WITH_PG_TDE=1
WITH_PG_REPACK=1
WITH_PLV8=1
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch) shift; [[ $# -gt 0 ]] || die "$1 requires a value"; TARGET="$1" ;;
    --postgresql-version=*) POSTGRESQL_VERSION="${1#*=}" ;;
    --postgresql-version) shift; [[ $# -gt 0 ]] || die "--postgresql-version requires a value"; POSTGRESQL_VERSION="$1" ;;
    --postgis-deps-version=*) POSTGIS_DEPS_VERSION="${1#*=}" ;;
    --postgis-deps-version) shift; [[ $# -gt 0 ]] || die "--postgis-deps-version requires a value"; POSTGIS_DEPS_VERSION="$1" ;;
    --groonga-version=*) GROONGA_VERSION="${1#*=}" ;;
    --groonga-version) shift; [[ $# -gt 0 ]] || die "--groonga-version requires a value"; GROONGA_VERSION="$1" ;;
    --v8-version=*) V8_VERSION="${1#*=}" ;;
    --v8-version) shift; [[ $# -gt 0 ]] || die "--v8-version requires a value"; V8_VERSION="$1" ;;
    --postgresql-archive=*) POSTGRESQL_ARCHIVE="${1#*=}" ;;
    --postgresql-archive) shift; [[ $# -gt 0 ]] || die "--postgresql-archive requires a value"; POSTGRESQL_ARCHIVE="$1" ;;
    --postgis-deps-archive=*) POSTGIS_DEPS_ARCHIVE="${1#*=}" ;;
    --postgis-deps-archive) shift; [[ $# -gt 0 ]] || die "--postgis-deps-archive requires a value"; POSTGIS_DEPS_ARCHIVE="$1" ;;
    --groonga-archive=*) GROONGA_ARCHIVE="${1#*=}" ;;
    --groonga-archive) shift; [[ $# -gt 0 ]] || die "--groonga-archive requires a value"; GROONGA_ARCHIVE="$1" ;;
    --fdw-deps-archive=*) FDW_DEPS_ARCHIVE="${1#*=}" ;;
    --fdw-deps-archive) shift; [[ $# -gt 0 ]] || die "--fdw-deps-archive requires a value"; FDW_DEPS_ARCHIVE="$1" ;;
    --v8-archive=*) V8_ARCHIVE="${1#*=}" ;;
    --v8-archive) shift; [[ $# -gt 0 ]] || die "--v8-archive requires a value"; V8_ARCHIVE="$1" ;;
    --oracle-sdk-archive=*) ORACLE_SDK_ARCHIVE="${1#*=}" ;;
    --oracle-sdk-archive) shift; [[ $# -gt 0 ]] || die "--oracle-sdk-archive requires a value"; ORACLE_SDK_ARCHIVE="$1" ;;
    --oracle-basic-archive=*) ORACLE_BASIC_ARCHIVE="${1#*=}" ;;
    --oracle-basic-archive) shift; [[ $# -gt 0 ]] || die "--oracle-basic-archive requires a value"; ORACLE_BASIC_ARCHIVE="$1" ;;
    --db2-cli-archive=*) DB2_CLI_ARCHIVE="${1#*=}" ;;
    --db2-cli-archive) shift; [[ $# -gt 0 ]] || die "--db2-cli-archive requires a value"; DB2_CLI_ARCHIVE="$1" ;;
    --db2-cli-dir=*) DB2_CLI_DIR="${1#*=}" ;;
    --db2-cli-dir) shift; [[ $# -gt 0 ]] || die "--db2-cli-dir requires a value"; DB2_CLI_DIR="$1" ;;
    --without-fdw) WITH_FDW=0; WITH_ORACLE_FDW=0; WITH_DB2_FDW=0 ;;
    --without-oracle-fdw) WITH_ORACLE_FDW=0 ;;
    --without-db2-fdw) WITH_DB2_FDW=0 ;;
    --without-pljava) WITH_PLJAVA=0 ;;
    --without-tde) WITH_PG_TDE=0 ;;
    --without-repack) WITH_PG_REPACK=0 ;;
    --without-plv8) WITH_PLV8=0 ;;
    --runtime=*) REQUESTED_RUNTIME="${1#*=}" ;;
    --runtime) shift; [[ $# -gt 0 ]] || die "--runtime requires a value"; REQUESTED_RUNTIME="$1" ;;
    --image=*|--linux-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image) shift; [[ $# -gt 0 ]] || die "--image requires a value"; BUILD_IMAGE="$1" ;;
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
resolve_target "$TARGET" "PostgreSQL 18 distribution target"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "postgresql18_dist supports Linux x86_64/aarch64/riscv64/loongarch64 and MinGW x86_64 package targets; got ${TARGET_KIND}:${ARCH}" ;;
esac

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="postgresql18_dist-${PACKAGE_TRIPLE}"
fi

if [[ -z "$POSTGRESQL_ARCHIVE" ]]; then
  POSTGRESQL_ARCHIVE="$(find_local_archive postgresql "postgresql-${POSTGRESQL_VERSION}-${PACKAGE_TRIPLE}.tar.xz")" \
    || die "missing PostgreSQL package archive for ${PACKAGE_TRIPLE}"
fi
if [[ -z "$POSTGIS_DEPS_ARCHIVE" ]]; then
  POSTGIS_DEPS_ARCHIVE="$(find_local_archive postgis_dependencies "postgis_dependencies-${PACKAGE_TRIPLE}.tar.xz")" \
    || die "missing postgis_dependencies archive for ${PACKAGE_TRIPLE}"
fi
if [[ -z "$GROONGA_ARCHIVE" ]]; then
  GROONGA_ARCHIVE="$(find_local_archive groonga "groonga-${GROONGA_VERSION}-${PACKAGE_TRIPLE}.tar.xz")" \
    || die "missing Groonga archive for ${PACKAGE_TRIPLE}"
fi
if [[ "$WITH_FDW" -eq 1 && -z "$FDW_DEPS_ARCHIVE" ]]; then
  FDW_DEPS_ARCHIVE="$(find_local_archive fdw_dependencies "fdw_dependencies-${PACKAGE_TRIPLE}.tar.xz")" \
    || die "missing fdw_dependencies archive for ${PACKAGE_TRIPLE}"
fi
if [[ "$WITH_PLV8" -eq 1 && -z "$V8_ARCHIVE" ]]; then
  V8_ARCHIVE="$(find_local_archive v8 "v8-${V8_VERSION}-${PACKAGE_TRIPLE}.tar.xz")" \
    || die "missing V8 archive for ${PACKAGE_TRIPLE}"
fi

REQUIRED_ARCHIVES=("$POSTGRESQL_ARCHIVE" "$POSTGIS_DEPS_ARCHIVE" "$GROONGA_ARCHIVE")
if [[ "$WITH_FDW" -eq 1 ]]; then
  REQUIRED_ARCHIVES+=("$FDW_DEPS_ARCHIVE")
fi
if [[ "$WITH_PLV8" -eq 1 ]]; then
  REQUIRED_ARCHIVES+=("$V8_ARCHIVE")
fi

for archive in "${REQUIRED_ARCHIVES[@]}"; do
  [[ -f "$archive" ]] || die "archive not found: ${archive}"
done
if [[ -n "$ORACLE_SDK_ARCHIVE" ]]; then
  [[ -f "$ORACLE_SDK_ARCHIVE" ]] || die "Oracle SDK archive not found: ${ORACLE_SDK_ARCHIVE}"
fi
if [[ -n "$ORACLE_BASIC_ARCHIVE" ]]; then
  [[ -f "$ORACLE_BASIC_ARCHIVE" ]] || die "Oracle Basic archive not found: ${ORACLE_BASIC_ARCHIVE}"
fi
if [[ -n "$DB2_CLI_ARCHIVE" ]]; then
  [[ -f "$DB2_CLI_ARCHIVE" ]] || die "DB2 CLI archive not found: ${DB2_CLI_ARCHIVE}"
fi
if [[ -n "$DB2_CLI_DIR" ]]; then
  [[ -d "$DB2_CLI_DIR" ]] || die "DB2 CLI directory not found: ${DB2_CLI_DIR}"
fi

CONTAINER_RUNTIME="$(resolve_container_runtime "$REQUESTED_RUNTIME")"
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_postgresql18_dist.sh" ]] || die "missing container script"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"
make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_BASE"
make_host_writable "$OUT_DIR"
make_host_writable "$DIST_DIR"
make_host_writable "$ARCHIVE_PATH"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning PostgreSQL 18 distribution target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
extract_prefix_archive "$OUT_DIR" "$POSTGRESQL_ARCHIVE"
extract_prefix_archive "$OUT_DIR" "$POSTGIS_DEPS_ARCHIVE"
extract_prefix_archive "$OUT_DIR" "$GROONGA_ARCHIVE"
if [[ "$WITH_FDW" -eq 1 ]]; then
  extract_prefix_archive "$OUT_DIR" "$FDW_DEPS_ARCHIVE"
fi
if [[ "$WITH_PLV8" -eq 1 ]]; then
  extract_prefix_archive "$OUT_DIR" "$V8_ARCHIVE"
fi
rewrite_overlay_prefixes "$OUT_DIR" "/opt/${PACKAGE_NAME}"
validate_base_postgresql "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  "$CONTAINER_RUNTIME" pull --platform linux/amd64 "$BUILD_IMAGE"
fi

EXTRA_MOUNTS=()
CONTAINER_ORACLE_SDK_ARCHIVE=""
CONTAINER_ORACLE_BASIC_ARCHIVE=""
CONTAINER_DB2_CLI_ARCHIVE=""
CONTAINER_DB2_CLI_DIR=""
if [[ -n "$ORACLE_SDK_ARCHIVE" ]]; then
  CONTAINER_ORACLE_SDK_ARCHIVE="/work/oracle/$(basename "$ORACLE_SDK_ARCHIVE")"
  EXTRA_MOUNTS+=(-v "$(cd "$(dirname "$ORACLE_SDK_ARCHIVE")" && pwd):/work/oracle:ro")
fi
if [[ -n "$ORACLE_BASIC_ARCHIVE" ]]; then
  CONTAINER_ORACLE_BASIC_ARCHIVE="/work/oracle/$(basename "$ORACLE_BASIC_ARCHIVE")"
  if [[ -z "$CONTAINER_ORACLE_SDK_ARCHIVE" ]]; then
    EXTRA_MOUNTS+=(-v "$(cd "$(dirname "$ORACLE_BASIC_ARCHIVE")" && pwd):/work/oracle:ro")
  fi
fi
if [[ -n "$DB2_CLI_DIR" ]]; then
  CONTAINER_DB2_CLI_DIR="/work/db2_cli"
  EXTRA_MOUNTS+=(-v "$(cd "$DB2_CLI_DIR" && pwd):${CONTAINER_DB2_CLI_DIR}:ro")
fi
if [[ -n "$DB2_CLI_ARCHIVE" ]]; then
  CONTAINER_DB2_CLI_ARCHIVE="/work/db2_archive/$(basename "$DB2_CLI_ARCHIVE")"
  EXTRA_MOUNTS+=(-v "$(cd "$(dirname "$DB2_CLI_ARCHIVE")" && pwd):/work/db2_archive:ro")
fi

echo "-- PostgreSQL 18 distribution build"
echo "-- runtime: ${CONTAINER_RUNTIME}"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

"$CONTAINER_RUNTIME" run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  "${EXTRA_MOUNTS[@]}" \
  --workdir /work \
  -e "ARCH=${ARCH}" \
  -e "TARGET_KIND=${TARGET_KIND}" \
  -e "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  -e "JOBS=${JOBS}" \
  -e "SDK_PREFIX=/opt/${PACKAGE_NAME}" \
  -e "ORACLE_SDK_ARCHIVE=${CONTAINER_ORACLE_SDK_ARCHIVE}" \
  -e "ORACLE_BASIC_ARCHIVE=${CONTAINER_ORACLE_BASIC_ARCHIVE}" \
  -e "DB2_CLI_ARCHIVE=${CONTAINER_DB2_CLI_ARCHIVE}" \
  -e "DB2_CLI_DIR=${CONTAINER_DB2_CLI_DIR}" \
  -e "WITH_FDW=${WITH_FDW}" \
  -e "WITH_ORACLE_FDW=${WITH_ORACLE_FDW}" \
  -e "WITH_DB2_FDW=${WITH_DB2_FDW}" \
  -e "WITH_PLJAVA=${WITH_PLJAVA}" \
  -e "WITH_PG_TDE=${WITH_PG_TDE}" \
  -e "WITH_PG_REPACK=${WITH_PG_REPACK}" \
  -e "WITH_PLV8=${WITH_PLV8}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_postgresql18_dist.sh

make_host_writable "$OUT_DIR"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"
chmod 664 "$ARCHIVE_PATH"

echo "-- PostgreSQL 18 distribution archive ready: ${ARCHIVE_PATH}"
