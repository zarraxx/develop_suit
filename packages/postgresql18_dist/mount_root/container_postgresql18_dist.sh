#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

download_archive() {
  local url="$1"
  local archive_name="$2"

  mkdir -p "$CACHE_DIR"
  if [[ ! -s "${CACHE_DIR}/${archive_name}" ]]; then
    rm -f "${CACHE_DIR:?}/${archive_name}" "${CACHE_DIR}/${archive_name}.tmp"
    log "Downloading ${archive_name}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive_name}.tmp" "$url"
    mv "${CACHE_DIR}/${archive_name}.tmp" "${CACHE_DIR}/${archive_name}"
  fi
}

extract_source() {
  local source_dir="$1"
  local archive_name="$2"
  local marker_path="$3"
  local archive_marker="${source_dir}/.source-archive"

  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    case "$archive_name" in
      *.zip)
        unzip -q "${CACHE_DIR}/${archive_name}" -d "${source_dir}.unzip"
        local first_dir=""
        first_dir="$(find "${source_dir}.unzip" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
        [[ -n "$first_dir" ]] || die "invalid zip archive: ${archive_name}"
        cp -a "${first_dir}/." "$source_dir/"
        rm -rf "${source_dir}.unzip"
        ;;
      *)
        tar -xf "${CACHE_DIR}/${archive_name}" -C "$source_dir" --strip-components=1
        ;;
    esac
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

apply_source_patch() {
  local source_dir="$1"
  local patch_path="$2"

  [[ -f "$patch_path" ]] || die "missing patch: ${patch_path}"
  (
    cd "$source_dir"
    if patch -N -p1 --dry-run -i "$patch_path" >/dev/null 2>&1; then
      patch -N -p1 -i "$patch_path"
    elif patch -R -p1 --dry-run -i "$patch_path" >/dev/null 2>&1; then
      :
    else
      die "patch cannot be applied cleanly: ${patch_path}"
    fi
  )
}

extension_env() {
  env \
    PATH="${SDK_PREFIX}/bin:${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}" \
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${SDK_PREFIX}/lib64:${LD_LIBRARY_PATH:-}" \
    PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR= \
    CC="$CC" \
    CXX="$CXX" \
    LD="${LD:-${LLVM_ROOT}/bin/ld.lld}" \
    AR="${AR:-${LLVM_ROOT}/bin/llvm-ar}" \
    RANLIB="${RANLIB:-${LLVM_ROOT}/bin/llvm-ranlib}" \
    NM="${NM:-${LLVM_ROOT}/bin/llvm-nm}" \
    STRIP="${STRIP:-${LLVM_ROOT}/bin/llvm-strip}" \
    CPPFLAGS="-I${SDK_PREFIX}/include ${CPPFLAGS:-}" \
    PG_CPPFLAGS="-I${SDK_PREFIX}/include ${PG_CPPFLAGS:-}" \
    CFLAGS="-I${SDK_PREFIX}/include -fPIC ${CFLAGS:-}" \
    CXXFLAGS="-I${SDK_PREFIX}/include -fPIC ${CXXFLAGS:-}" \
    LDFLAGS="-L${SDK_PREFIX}/lib -Wl,-rpath,${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib ${LDFLAGS:-}" \
    "$@"
}

make_pgxs_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  log "Building PGXS extension: ${package_name}"
  (
    cd "$source_dir"
    extension_env make -j "$JOBS" PG_CONFIG="$PG_CONFIG" USE_PGXS=1 "$@"
    extension_env make install PG_CONFIG="$PG_CONFIG" USE_PGXS=1 "$@"
  )
  INSTALLED_EXTENSIONS+=("$package_name")
}

cmake_extension_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local build_dir="${EXT_BUILD_DIR}/${package_name}"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  log "Configuring CMake extension: ${package_name}"
  extension_env cmake -S "$source_dir" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_PREFIX_PATH="$SDK_PREFIX" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="-I${SDK_PREFIX}/include -fPIC" \
    -DCMAKE_CXX_FLAGS="-I${SDK_PREFIX}/include -fPIC" \
    -DCMAKE_EXE_LINKER_FLAGS="-L${SDK_PREFIX}/lib -Wl,-rpath,${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L${SDK_PREFIX}/lib -Wl,-rpath,${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib" \
    "$@"

  extension_env cmake --build "$build_dir" --parallel "$JOBS"
  extension_env cmake --install "$build_dir"
  INSTALLED_EXTENSIONS+=("$package_name")
}

meson_extension_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local build_dir="${EXT_BUILD_DIR}/${package_name}"
  rm -rf "$build_dir"

  log "Configuring Meson extension: ${package_name}"
  extension_env meson setup "$build_dir" "$source_dir" \
    --prefix="$SDK_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    "$@"
  extension_env meson compile -C "$build_dir" -j "$JOBS"
  extension_env meson install -C "$build_dir"
  INSTALLED_EXTENSIONS+=("$package_name")
}

install_oracle_client_for_build() {
  [[ -n "$ORACLE_SDK_ARCHIVE" && -n "$ORACLE_BASIC_ARCHIVE" ]] || return 0

  require_command unzip
  ORACLE_HOME="${BUILD_DIR}/oracle/instantclient"
  rm -rf "${BUILD_DIR}/oracle"
  mkdir -p "${BUILD_DIR}/oracle"
  unzip -q "$ORACLE_BASIC_ARCHIVE" -d "${BUILD_DIR}/oracle"
  unzip -q "$ORACLE_SDK_ARCHIVE" -d "${BUILD_DIR}/oracle"
  ORACLE_HOME="$(find "${BUILD_DIR}/oracle" -mindepth 1 -maxdepth 1 -type d -name 'instantclient*' | sort | head -n 1)"
  [[ -n "$ORACLE_HOME" && -d "$ORACLE_HOME/sdk/include" ]] || die "invalid Oracle Instant Client archives"
  export ORACLE_HOME
  export LD_LIBRARY_PATH="${ORACLE_HOME}:${LD_LIBRARY_PATH:-}"
}

install_db2_cli_for_build() {
  [[ -n "$DB2_CLI_DIR" ]] || return 0

  [[ -d "$DB2_CLI_DIR/include" ]] || die "DB2 CLI directory missing include: ${DB2_CLI_DIR}"
  [[ -d "$DB2_CLI_DIR/lib" ]] || die "DB2 CLI directory missing lib: ${DB2_CLI_DIR}"
  export DB2_HOME="$DB2_CLI_DIR"
  export IBM_DB_HOME="$DB2_CLI_DIR"
  export LD_LIBRARY_PATH="${DB2_CLI_DIR}/lib:${LD_LIBRARY_PATH:-}"
}

build_postgis() {
  local source_dir="${EXT_SOURCE_DIR}/postgis"
  local build_dir="${EXT_BUILD_DIR}/postgis"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  log "Configuring extension: postgis"
  (
    cd "$build_dir"
    extension_env \
      XML2_CONFIG="${SDK_PREFIX}/bin/xml2-config" \
      LIBXML2_CFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/libxml2" \
      LIBXML2_LIBS="-L${SDK_PREFIX}/lib -lxml2 -lz -liconv -lm -lpthread" \
      LIBS="-L${SDK_PREFIX}/lib -liconv -lpthread ${LIBS:-}" \
      CFLAGS="-I${SDK_PREFIX}/include -fPIC -pthread ${CFLAGS:-}" \
      LDFLAGS="-L${SDK_PREFIX}/lib -Wl,-rpath,${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib -pthread ${LDFLAGS:-}" \
      PERL="${BUILD_TOOLS}/perl" \
      CPPBIN="$CC -E -x c" \
      "${source_dir}/configure" \
      --prefix="$SDK_PREFIX" \
      --with-pgconfig="$PG_CONFIG" \
      --with-geosconfig="${SDK_PREFIX}/bin/geos-config" \
      --with-gdalconfig="${SDK_PREFIX}/bin/gdal-config" \
      --with-sfcgal="${SDK_PREFIX}/bin/sfcgal-config" \
      --without-protobuf
    extension_env make -j "$JOBS"
    extension_env make install
  )
  INSTALLED_EXTENSIONS+=(postgis)
}

build_pgrouting() {
  cmake_extension_install pgrouting "${EXT_SOURCE_DIR}/pgrouting" \
    -DPOSTGRESQL_PG_CONFIG="$PG_CONFIG" \
    -DPOSTGRESQL_BIN="${SDK_PREFIX}/bin" \
    -DPERL_EXECUTABLE="${BUILD_TOOLS}/perl" \
    -DWITH_DOC=OFF \
    -DWITH_INTERNAL_TESTS=OFF
}

build_timescaledb() {
  local source_dir="${EXT_SOURCE_DIR}/timescaledb"
  local build_dir="${EXT_BUILD_DIR}/timescaledb"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  log "Configuring extension: timescaledb"
  extension_env cmake -S "$source_dir" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DPG_CONFIG="$PG_CONFIG" \
    -DREGRESS_CHECKS=OFF \
    -DWARNINGS_AS_ERRORS=OFF \
    -DPROJECT_INSTALL_METHOD="source" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DOPENSSL_ROOT_DIR="$SDK_PREFIX"
  extension_env cmake --build "$build_dir" --parallel "$JOBS"
  extension_env cmake --install "$build_dir"
  INSTALLED_EXTENSIONS+=(timescaledb)
}

build_plv8() {
  local source_dir="${EXT_SOURCE_DIR}/plv8"

  apply_source_patch "$source_dir" "/work/mount_root/patch/plv8-3.2.4-external-v8-prefix.patch"
  make_pgxs_install plv8 "$source_dir" V8_PREFIX="$SDK_PREFIX"
}

build_pgmq() {
  make_pgxs_install pgmq "${EXT_SOURCE_DIR}/pgmq/pgmq-extension"
}

build_pg_tde() {
  local source_dir="${EXT_SOURCE_DIR}/pg_tde"

  if [[ ! -f "${source_dir}/src/libkmip/libkmip/include/kmip.h" ]]; then
    log "Skipping pg_tde: release archive does not include the libkmip submodule"
    SKIPPED_EXTENSIONS+=("pg_tde: missing libkmip submodule in upstream release archive")
    return 0
  fi

  if [[ ! -f "${SDK_PREFIX}/include/server/access/xlog_smgr.h" ]]; then
    log "Skipping pg_tde: PostgreSQL package does not install access/xlog_smgr.h"
    SKIPPED_EXTENSIONS+=("pg_tde: requires PostgreSQL private header access/xlog_smgr.h")
    return 0
  fi

  make_pgxs_install pg_tde "$source_dir"
}

build_pg_repack() {
  if [[ ! -e "${SDK_PREFIX}/lib/libpgcommon.a" || ! -e "${SDK_PREFIX}/lib/libpgport.a" ]]; then
    log "Skipping pg_repack: PostgreSQL package does not include libpgcommon.a/libpgport.a"
    SKIPPED_EXTENSIONS+=("pg_repack: requires PostgreSQL libpgcommon.a and libpgport.a development archives")
    return 0
  fi

  make_pgxs_install pg_repack "${EXT_SOURCE_DIR}/pg_repack"
}

build_mysql_fdw() {
  [[ -x "${SDK_PREFIX}/bin/mariadb_config" ]] || die "missing mariadb_config for mysql_fdw"
  [[ -f "${SDK_PREFIX}/include/mariadb/mysql.h" ]] || die "missing MariaDB/MySQL headers for mysql_fdw"

  if [[ ! -e "${SDK_PREFIX}/lib/libmysqlclient.so" && -e "${SDK_PREFIX}/lib/mariadb/libmysqlclient.so" ]]; then
    ln -s "mariadb/libmysqlclient.so" "${SDK_PREFIX}/lib/libmysqlclient.so"
  fi
  if [[ ! -e "${SDK_PREFIX}/lib/libmariadb.so.3" && -e "${SDK_PREFIX}/lib/mariadb/libmariadb.so.3" ]]; then
    ln -s "mariadb/libmariadb.so.3" "${SDK_PREFIX}/lib/libmariadb.so.3"
  fi

  make_pgxs_install mysql_fdw "${EXT_SOURCE_DIR}/mysql_fdw" \
    MYSQL_CONFIG="${SDK_PREFIX}/bin/mariadb_config"
}

build_tds_fdw() {
  [[ -f "${SDK_PREFIX}/include/sybfront.h" ]] || die "missing FreeTDS sybfront.h for tds_fdw"
  [[ -f "${SDK_PREFIX}/lib/libsybdb.so" ]] || die "missing FreeTDS libsybdb.so for tds_fdw"

  make_pgxs_install tds_fdw "${EXT_SOURCE_DIR}/tds_fdw" \
    TDS_INCLUDE="-I${SDK_PREFIX}/include" \
    SHLIB_LINK="-L${SDK_PREFIX}/lib -lsybdb"
}

build_sqlite_fdw() {
  log "Skipping sqlite_fdw: upstream release does not support PostgreSQL 18"
  SKIPPED_EXTENSIONS+=("sqlite_fdw: upstream release supports PostgreSQL 13-17, not PostgreSQL 18")
}

build_mongo_fdw() {
  [[ -f "${SDK_PREFIX}/include/libmongoc-1.0/mongoc/mongoc.h" ]] || die "missing mongo-c-driver 1.x headers for mongo_fdw"
  [[ -f "${SDK_PREFIX}/include/libbson-1.0/bson/bson.h" ]] || die "missing libbson 1.x headers for mongo_fdw"
  [[ -f "${SDK_PREFIX}/include/json-c/json.h" ]] || die "missing json-c headers for mongo_fdw"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libmongoc-1.0.so*' | grep -q . || die "missing libmongoc-1.0 for mongo_fdw"
  find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libbson-1.0.so*' | grep -q . || die "missing libbson-1.0 for mongo_fdw"
  [[ -f "${SDK_PREFIX}/lib/libjson-c.so" ]] || die "missing libjson-c for mongo_fdw"

  make_pgxs_install mongo_fdw "${EXT_SOURCE_DIR}/mongo_fdw" \
    LIBJSON_OBJS= \
    PG_CPPFLAGS="--std=c99 -I${SDK_PREFIX}/include/libmongoc-1.0 -I${SDK_PREFIX}/include/libbson-1.0 -I${SDK_PREFIX}/include/json-c -I${SDK_PREFIX}/include" \
    SHLIB_LINK="-L${SDK_PREFIX}/lib -lmongoc-1.0 -lbson-1.0 -ljson-c"
}

build_oracle_fdw() {
  [[ -n "$ORACLE_HOME" ]] || {
    log "Skipping oracle_fdw: Oracle Instant Client SDK/Basic archives were not provided"
    SKIPPED_EXTENSIONS+=("oracle_fdw: Oracle Instant Client SDK/Basic archives were not provided")
    return 0
  }
  make_pgxs_install oracle_fdw "${EXT_SOURCE_DIR}/oracle_fdw"
  rm -rf "${SDK_PREFIX}/instantclient" "${SDK_PREFIX}/lib/libclntsh"* "${SDK_PREFIX}/lib/libocci"*
}

build_db2_fdw() {
  [[ -n "${DB2_HOME:-}" ]] || {
    log "Skipping db2_fdw: DB2 CLI directory was not provided"
    SKIPPED_EXTENSIONS+=("db2_fdw: DB2 CLI directory was not provided")
    return 0
  }
  make_pgxs_install db2_fdw "${EXT_SOURCE_DIR}/db2_fdw"
  rm -f "${SDK_PREFIX}/lib/libdb2."*
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" -type f -name '*.a' -delete 2>/dev/null || true
}

write_distribution_readme() {
  local extension_lines=""
  local skipped_lines=""
  local extension_name=""

  for extension_name in "${INSTALLED_EXTENSIONS[@]}"; do
    extension_lines+="- ${extension_name}"$'\n'
  done
  for extension_name in "${SKIPPED_EXTENSIONS[@]}"; do
    skipped_lines+="- ${extension_name}"$'\n'
  done
  [[ -n "$skipped_lines" ]] || skipped_lines="- none"$'\n'

  render_template "/work/mount_root/templates/README.postgresql18-dist.in" \
    "${SDK_PREFIX}/README.postgresql18-dist" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "POSTGRESQL_VERSION=${POSTGRESQL_VERSION}" \
    "INSTALLED_EXTENSIONS=${extension_lines}" \
    "SKIPPED_EXTENSIONS=${skipped_lines}"
}

write_exec_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec env -u LD_LIBRARY_PATH "${real_tool}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_common_build_tool_wrappers() {
  local tool_name=""
  local real_tool=""

  for tool_name in perl python python3; do
    real_tool="$(command -v "$tool_name" 2>/dev/null || true)"
    if [[ -n "$real_tool" ]]; then
      write_exec_wrapper "${BUILD_TOOLS}/${tool_name}" "$real_tool"
    fi
  done
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/postgresql18_dist-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
ORACLE_SDK_ARCHIVE="${ORACLE_SDK_ARCHIVE:-}"
ORACLE_BASIC_ARCHIVE="${ORACLE_BASIC_ARCHIVE:-}"
DB2_CLI_DIR="${DB2_CLI_DIR:-}"

POSTGRESQL_VERSION="${POSTGRESQL_VERSION:-18.4}"
PGVECTOR_VERSION="${PGVECTOR_VERSION:-0.8.3}"
AGE_VERSION="${AGE_VERSION:-1.7.0}"
PGROONGA_VERSION="${PGROONGA_VERSION:-4.0.6}"
POSTGIS_VERSION="${POSTGIS_VERSION:-3.6.4}"
PGROUTING_VERSION="${PGROUTING_VERSION:-4.0.1}"
PG_CRON_VERSION="${PG_CRON_VERSION:-1.6.7}"
PG_PARTMAN_VERSION="${PG_PARTMAN_VERSION:-5.4.3}"
PG_NET_VERSION="${PG_NET_VERSION:-0.20.3}"
PGSQL_HTTP_VERSION="${PGSQL_HTTP_VERSION:-1.7.1}"
PGMQ_VERSION="${PGMQ_VERSION:-1.11.1}"
PLV8_VERSION="${PLV8_VERSION:-3.2.4}"
TIMESCALEDB_VERSION="${TIMESCALEDB_VERSION:-2.28.0}"
PGAUDIT_VERSION="${PGAUDIT_VERSION:-18.0}"
PG_STAT_MONITOR_VERSION="${PG_STAT_MONITOR_VERSION:-2.3.2}"
PG_TDE_VERSION="${PG_TDE_VERSION:-2.2.0}"
SET_USER_VERSION="${SET_USER_VERSION:-REL4_2_0}"
PG_REPACK_VERSION="${PG_REPACK_VERSION:-1.5.3}"
MYSQL_FDW_VERSION="${MYSQL_FDW_VERSION:-2_9_3}"
TDS_FDW_VERSION="${TDS_FDW_VERSION:-2.0.5}"
SQLITE_FDW_VERSION="${SQLITE_FDW_VERSION:-2.5.0}"
MONGO_FDW_VERSION="${MONGO_FDW_VERSION:-5_5_3}"
ORACLE_FDW_VERSION="${ORACLE_FDW_VERSION:-2_9_0}"
DB2_FDW_VERSION="${DB2_FDW_VERSION:-18.1.2}"

[[ "$TARGET_KIND" == "linux" ]] || die "container currently supports Linux targets"
[[ "$ARCH" == "x86_64" ]] || die "container currently supports x86_64 first"
[[ -d "$SDK_PREFIX" ]] || die "missing distribution prefix: ${SDK_PREFIX}"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"

require_command curl
require_command tar
require_command unzip
require_command make
require_command cmake
require_command ninja
require_command meson
require_command pkg-config
require_command patch

PG_CONFIG="${SDK_PREFIX}/bin/pg_config"
[[ -x "$PG_CONFIG" ]] || die "missing pg_config: ${PG_CONFIG}"

SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TOOLS="${BUILD_DIR}/tools"
EXT_SOURCE_DIR="${BUILD_DIR}/src/postgresql18_dist"
EXT_BUILD_DIR="${BUILD_DIR}/build/postgresql18_dist"
mkdir -p "$BUILD_TOOLS" "$EXT_SOURCE_DIR" "$EXT_BUILD_DIR"
write_noop_ldconfig_wrapper "$BUILD_TOOLS"
write_common_build_tool_wrappers

CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang++}"
[[ -x "$CC" ]] || CC="${LLVM_ROOT}/bin/clang"
[[ -x "$CXX" ]] || CXX="${LLVM_ROOT}/bin/clang++"
[[ -x "$CC" ]] || die "missing C compiler"
[[ -x "$CXX" ]] || die "missing C++ compiler"

export PATH="${SDK_PREFIX}/bin:${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
export LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${SDK_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=

download_archive "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" "pgvector-${PGVECTOR_VERSION}.tar.gz"
download_archive "https://github.com/apache/age/releases/download/PG18%2Fv1.7.0-rc0/apache-age-${AGE_VERSION}-src.tar.gz" "apache-age-${AGE_VERSION}-src.tar.gz"
download_archive "https://packages.groonga.org/source/pgroonga/pgroonga-${PGROONGA_VERSION}.tar.gz" "pgroonga-${PGROONGA_VERSION}.tar.gz"
download_archive "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" "postgis-${POSTGIS_VERSION}.tar.gz"
download_archive "https://github.com/pgRouting/pgrouting/releases/download/v${PGROUTING_VERSION}/pgrouting-${PGROUTING_VERSION}.tar.gz" "pgrouting-${PGROUTING_VERSION}.tar.gz"
download_archive "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" "pg_cron-${PG_CRON_VERSION}.tar.gz"
download_archive "https://github.com/pgpartman/pg_partman/archive/refs/tags/v${PG_PARTMAN_VERSION}.tar.gz" "pg_partman-${PG_PARTMAN_VERSION}.tar.gz"
download_archive "https://github.com/supabase/pg_net/archive/refs/tags/v${PG_NET_VERSION}.tar.gz" "pg_net-${PG_NET_VERSION}.tar.gz"
download_archive "https://github.com/pramsey/pgsql-http/archive/refs/tags/v${PGSQL_HTTP_VERSION}.tar.gz" "pgsql-http-${PGSQL_HTTP_VERSION}.tar.gz"
download_archive "https://github.com/pgmq/pgmq/archive/refs/tags/v${PGMQ_VERSION}.tar.gz" "pgmq-${PGMQ_VERSION}.tar.gz"
download_archive "https://github.com/plv8/plv8/archive/refs/tags/v${PLV8_VERSION}.tar.gz" "plv8-${PLV8_VERSION}.tar.gz"
download_archive "https://github.com/timescale/timescaledb/archive/refs/tags/${TIMESCALEDB_VERSION}.tar.gz" "timescaledb-${TIMESCALEDB_VERSION}.tar.gz"
download_archive "https://github.com/pgaudit/pgaudit/archive/refs/tags/${PGAUDIT_VERSION}.tar.gz" "pgaudit-${PGAUDIT_VERSION}.tar.gz"
download_archive "https://github.com/percona/pg_stat_monitor/archive/refs/tags/${PG_STAT_MONITOR_VERSION}.tar.gz" "pg_stat_monitor-${PG_STAT_MONITOR_VERSION}.tar.gz"
download_archive "https://github.com/percona/pg_tde/archive/refs/tags/${PG_TDE_VERSION}.tar.gz" "pg_tde-${PG_TDE_VERSION}.tar.gz"
download_archive "https://github.com/pgaudit/set_user/archive/refs/tags/${SET_USER_VERSION}.tar.gz" "set_user-${SET_USER_VERSION}.tar.gz"
download_archive "https://github.com/reorg/pg_repack/archive/refs/tags/ver_${PG_REPACK_VERSION}.tar.gz" "pg_repack-${PG_REPACK_VERSION}.tar.gz"
download_archive "https://github.com/pg-redis-fdw/redis_fdw/archive/refs/heads/REL_18_STABLE.zip" "redis_fdw-REL_18_STABLE.zip"
download_archive "https://github.com/EnterpriseDB/mysql_fdw/archive/refs/tags/REL-${MYSQL_FDW_VERSION}.tar.gz" "mysql_fdw-${MYSQL_FDW_VERSION}.tar.gz"
download_archive "https://github.com/tds-fdw/tds_fdw/archive/refs/tags/v${TDS_FDW_VERSION}.tar.gz" "tds_fdw-${TDS_FDW_VERSION}.tar.gz"
download_archive "https://github.com/pgspider/sqlite_fdw/archive/refs/tags/v${SQLITE_FDW_VERSION}.tar.gz" "sqlite_fdw-${SQLITE_FDW_VERSION}.tar.gz"
download_archive "https://github.com/EnterpriseDB/mongo_fdw/archive/refs/tags/REL-${MONGO_FDW_VERSION}.tar.gz" "mongo_fdw-${MONGO_FDW_VERSION}.tar.gz"
download_archive "https://github.com/laurenz/oracle_fdw/archive/refs/tags/ORACLE_FDW_${ORACLE_FDW_VERSION}.tar.gz" "oracle_fdw-${ORACLE_FDW_VERSION}.tar.gz"
download_archive "https://github.com/pg-fdw/db2_fdw/releases/download/${DB2_FDW_VERSION}/db2_fdw-${DB2_FDW_VERSION}.zip" "db2_fdw-${DB2_FDW_VERSION}.zip"

extract_source "${EXT_SOURCE_DIR}/pgvector" "pgvector-${PGVECTOR_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/age" "apache-age-${AGE_VERSION}-src.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pgroonga" "pgroonga-${PGROONGA_VERSION}.tar.gz" "meson.build"
extract_source "${EXT_SOURCE_DIR}/postgis" "postgis-${POSTGIS_VERSION}.tar.gz" "configure"
extract_source "${EXT_SOURCE_DIR}/pgrouting" "pgrouting-${PGROUTING_VERSION}.tar.gz" "CMakeLists.txt"
extract_source "${EXT_SOURCE_DIR}/pg_cron" "pg_cron-${PG_CRON_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pg_partman" "pg_partman-${PG_PARTMAN_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pg_net" "pg_net-${PG_NET_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pgsql-http" "pgsql-http-${PGSQL_HTTP_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pgmq" "pgmq-${PGMQ_VERSION}.tar.gz" "pgmq-extension/Makefile"
extract_source "${EXT_SOURCE_DIR}/plv8" "plv8-${PLV8_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/timescaledb" "timescaledb-${TIMESCALEDB_VERSION}.tar.gz" "CMakeLists.txt"
extract_source "${EXT_SOURCE_DIR}/pgaudit" "pgaudit-${PGAUDIT_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pg_stat_monitor" "pg_stat_monitor-${PG_STAT_MONITOR_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pg_tde" "pg_tde-${PG_TDE_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/set_user" "set_user-${SET_USER_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pg_repack" "pg_repack-${PG_REPACK_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/redis_fdw" "redis_fdw-REL_18_STABLE.zip" "Makefile"
extract_source "${EXT_SOURCE_DIR}/mysql_fdw" "mysql_fdw-${MYSQL_FDW_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/tds_fdw" "tds_fdw-${TDS_FDW_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/sqlite_fdw" "sqlite_fdw-${SQLITE_FDW_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/mongo_fdw" "mongo_fdw-${MONGO_FDW_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/oracle_fdw" "oracle_fdw-${ORACLE_FDW_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/db2_fdw" "db2_fdw-${DB2_FDW_VERSION}.zip" "Makefile"

INSTALLED_EXTENSIONS=()
SKIPPED_EXTENSIONS=()
ORACLE_HOME=""
install_oracle_client_for_build
install_db2_cli_for_build

make_pgxs_install vector "${EXT_SOURCE_DIR}/pgvector"
make_pgxs_install age "${EXT_SOURCE_DIR}/age"
meson_extension_install pgroonga "${EXT_SOURCE_DIR}/pgroonga" \
  -Dpg_config="$PG_CONFIG" \
  -Dinstall_to_postgresql=true \
  -Dtest=false
build_postgis
build_pgrouting
make_pgxs_install pg_cron "${EXT_SOURCE_DIR}/pg_cron"
make_pgxs_install pg_partman "${EXT_SOURCE_DIR}/pg_partman"
make_pgxs_install pg_net "${EXT_SOURCE_DIR}/pg_net"
make_pgxs_install pgsql-http "${EXT_SOURCE_DIR}/pgsql-http" \
  CURL_CONFIG="${SDK_PREFIX}/bin/curl-config" \
  PG_CPPFLAGS="-I${SDK_PREFIX}/include" \
  SHLIB_LINK="-L${SDK_PREFIX}/lib -lcurl"
build_pgmq
build_plv8
build_timescaledb
make_pgxs_install pgaudit "${EXT_SOURCE_DIR}/pgaudit"
make_pgxs_install pg_stat_monitor "${EXT_SOURCE_DIR}/pg_stat_monitor"
build_pg_tde
make_pgxs_install set_user "${EXT_SOURCE_DIR}/set_user"
build_pg_repack
make_pgxs_install redis_fdw "${EXT_SOURCE_DIR}/redis_fdw"
build_mysql_fdw
build_tds_fdw
build_sqlite_fdw
build_mongo_fdw
build_oracle_fdw
build_db2_fdw

remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
write_distribution_readme

log "PostgreSQL 18 distribution package ready: ${SDK_PREFIX}"
