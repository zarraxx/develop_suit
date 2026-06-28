#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

is_enabled() {
  [[ "${1:-1}" == "1" || "${1:-1}" == "true" || "${1:-1}" == "yes" ]]
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

generate_mingw_import_library() {
  local dll_path="$1"
  local output_lib="$2"
  local library_name="${3:-$(basename "$dll_path")}"
  local def_file="${output_lib}.def"

  [[ -f "$dll_path" ]] || die "missing DLL for import library generation: ${dll_path}"
  require_command "${LLVM_ROOT}/bin/llvm-objdump"
  require_command "${LLVM_ROOT}/bin/llvm-dlltool"

  {
    printf 'LIBRARY %s\n' "$library_name"
    printf 'EXPORTS\n'
    "${LLVM_ROOT}/bin/llvm-objdump" -p "$dll_path" \
      | awk '/^[[:space:]]*[0-9]+[[:space:]]+0x[[:xdigit:]]+[[:space:]]+[[:graph:]]+$/ { print $3 }'
  } >"$def_file"

  [[ "$(wc -l <"$def_file")" -gt 2 ]] || die "could not read exports from DLL: ${dll_path}"
  "${LLVM_ROOT}/bin/llvm-dlltool" -m i386:x86-64 -d "$def_file" -l "$output_lib"
  rm -f "$def_file"
}

extension_env() {
  local ld_library_path="${SDK_PREFIX}/lib:${SDK_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    ld_library_path="${SDK_PREFIX}/bin:${ld_library_path}"
  fi

  env \
    PATH="${BUILD_TOOLS}:${SDK_PREFIX}/bin:${LLVM_ROOT}/bin:${PATH}" \
    LD_LIBRARY_PATH="${ld_library_path}" \
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
    WINDRES="${WINDRES:-}" \
    CPPFLAGS="${COMMON_CPPFLAGS} ${CPPFLAGS:-}" \
    PG_CPPFLAGS="${COMMON_PG_CPPFLAGS} ${PG_CPPFLAGS:-}" \
    CFLAGS="${COMMON_CFLAGS} ${CFLAGS:-}" \
    CXXFLAGS="${COMMON_CXXFLAGS} ${CXXFLAGS:-}" \
    LDFLAGS="${COMMON_LDFLAGS} ${LDFLAGS:-}" \
    "$@"
}

make_pgxs_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  log "Building PGXS extension: ${package_name}"
  (
    cd "$source_dir"
    extension_env make -j "$JOBS" PG_CONFIG="$PG_CONFIG" USE_PGXS=1 with_llvm=no "$@"
    extension_env make install PG_CONFIG="$PG_CONFIG" USE_PGXS=1 with_llvm=no "$@"
  )
  INSTALLED_EXTENSIONS+=("$package_name")
}

cmake_extension_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local build_dir="${EXT_BUILD_DIR}/${package_name}"
  local cmake_target_args=()
  local cmake_rpath_args=()
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cmake_target_args+=(
      -DCMAKE_SYSTEM_NAME=Windows
      -DCMAKE_RC_COMPILER="$WINDRES"
      -DCMAKE_DLL_NAME_WITH_SOVERSION=ON
    )
  else
    cmake_rpath_args+=(
      "-DCMAKE_INSTALL_RPATH=${SDK_PREFIX}/lib"
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF
      -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF
    )
  fi

  log "Configuring CMake extension: ${package_name}"
  extension_env cmake -S "$source_dir" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_PREFIX_PATH="$SDK_PREFIX" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="${COMMON_CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXXFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${COMMON_LDFLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${COMMON_LDFLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${COMMON_LDFLAGS}" \
    "${cmake_target_args[@]}" \
    "${cmake_rpath_args[@]}" \
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
    --cross-file="${MESON_CROSS_FILE}" \
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
  unzip -oq "$ORACLE_BASIC_ARCHIVE" -d "${BUILD_DIR}/oracle"
  unzip -oq "$ORACLE_SDK_ARCHIVE" -d "${BUILD_DIR}/oracle"
  ORACLE_HOME="$(find "${BUILD_DIR}/oracle" -mindepth 1 -maxdepth 1 -type d -name 'instantclient*' | sort | head -n 1)"
  [[ -n "$ORACLE_HOME" && -d "$ORACLE_HOME/sdk/include" ]] || die "invalid Oracle Instant Client archives"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    generate_mingw_import_library "${ORACLE_HOME}/oci.dll" "${ORACLE_HOME}/liboci.a" "oci.dll"
  fi
  export ORACLE_HOME
  export LD_LIBRARY_PATH="${ORACLE_HOME}:${LD_LIBRARY_PATH:-}"
}

install_db2_cli_for_build() {
  if [[ -z "$DB2_CLI_DIR" && -n "$DB2_CLI_ARCHIVE" ]]; then
    local db2_extract_dir="${BUILD_DIR}/db2_cli"
    rm -rf "$db2_extract_dir"
    mkdir -p "$db2_extract_dir"
    case "$DB2_CLI_ARCHIVE" in
      *.zip)
        require_command unzip
        unzip -oq "$DB2_CLI_ARCHIVE" -d "$db2_extract_dir"
        ;;
      *.tar|*.tar.gz|*.tgz)
        tar -xf "$DB2_CLI_ARCHIVE" -C "$db2_extract_dir"
        ;;
      *)
        die "unsupported DB2 CLI archive type: ${DB2_CLI_ARCHIVE}"
        ;;
    esac
    DB2_CLI_DIR="$(
      find "$db2_extract_dir" -type d -name clidriver \
        | sort \
        | head -n 1
    )"
    [[ -n "$DB2_CLI_DIR" ]] || die "could not find clidriver in DB2 CLI archive"
  fi

  [[ -n "$DB2_CLI_DIR" ]] || return 0

  [[ -d "$DB2_CLI_DIR/include" ]] || die "DB2 CLI directory missing include: ${DB2_CLI_DIR}"
  [[ -d "$DB2_CLI_DIR/lib" ]] || die "DB2 CLI directory missing lib: ${DB2_CLI_DIR}"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    generate_mingw_import_library "${DB2_CLI_DIR}/bin/db2app64.dll" "${DB2_CLI_DIR}/lib/libdb2.a" "db2app64.dll"
  fi
  export DB2_HOME="$DB2_CLI_DIR"
  export IBM_DB_HOME="$DB2_CLI_DIR"
  export LD_LIBRARY_PATH="${DB2_CLI_DIR}/lib:${LD_LIBRARY_PATH:-}"
}

build_postgis() {
  local source_dir="${EXT_SOURCE_DIR}/postgis"
  local build_dir="${EXT_BUILD_DIR}/postgis"
  local extra_libs="-L${SDK_PREFIX}/lib -liconv"
  local extra_cflags="${COMMON_CFLAGS}"
  local extra_ldflags="${COMMON_LDFLAGS}"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch "$source_dir" "/work/mount_root/patch/postgis-3.6.4-mingw-export-st-symdifference.patch"
    apply_source_patch "$source_dir" "/work/mount_root/patch/postgis-3.6.4-mingw-export-gserialized-estimate.patch"
  fi

  if [[ "$TARGET_KIND" == "linux" ]]; then
    extra_libs+=" -lpthread"
    extra_cflags+=" -pthread"
    extra_ldflags+=" -pthread"
  else
    extra_cflags+=" -Wno-error=dll-attribute-on-redeclaration"
    if [[ ! -e "${SDK_PREFIX}/lib/libproj_9.dll.a" && -e "${SDK_PREFIX}/lib/libproj.dll.a" ]]; then
      ln -s "libproj.dll.a" "${SDK_PREFIX}/lib/libproj_9.dll.a"
    fi
  fi

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  log "Configuring extension: postgis"
  (
    cd "$build_dir"
    extension_env \
      XML2_CONFIG="${SDK_PREFIX}/bin/xml2-config" \
      LIBXML2_CFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/libxml2" \
      LIBXML2_LIBS="-L${SDK_PREFIX}/lib -lxml2 -lz -liconv -lm" \
      LIBS="${extra_libs} ${LIBS:-}" \
      CFLAGS="${extra_cflags} ${CFLAGS:-}" \
      LDFLAGS="${extra_ldflags} ${LDFLAGS:-}" \
      PERL="${BUILD_TOOLS}/perl" \
      CPPBIN="$CC -E -x c" \
      "${source_dir}/configure" \
      --build="${BUILD_TRIPLE}" \
      --host="$CONFIGURE_HOST_TRIPLE" \
      --prefix="$SDK_PREFIX" \
      --with-pgconfig="$PG_CONFIG" \
      --with-geosconfig="${SDK_PREFIX}/bin/geos-config" \
      --with-gdalconfig="${SDK_PREFIX}/bin/gdal-config" \
      --with-sfcgal="${SDK_PREFIX}/bin/sfcgal-config" \
      --without-protobuf
    mkdir -p "${build_dir}/liblwgeom/topo"
    extension_env make -j "$JOBS" CXX="$CXX" with_llvm=no
    extension_env make install CXX="$CXX" with_llvm=no
  )
  INSTALLED_EXTENSIONS+=(postgis)
}

build_pgrouting() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping pgrouting: PostgreSQL Win32 header macros conflict with libc++ locale support under MinGW"
    SKIPPED_EXTENSIONS+=("pgrouting: disabled on MinGW due to win32_port.h locale/ctype macro conflicts with libc++")
    return 0
  fi

  cmake_extension_install pgrouting "${EXT_SOURCE_DIR}/pgrouting" \
    -DPOSTGRESQL_PG_CONFIG="$PG_CONFIG" \
    -DPOSTGRESQL_BIN="${SDK_PREFIX}/bin" \
    -DPERL_EXECUTABLE="${BUILD_TOOLS}/perl" \
    -DWITH_DOC=OFF \
    -DWITH_INTERNAL_TESTS=OFF
}

build_pg_cron() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping pg_cron: upstream sources require POSIX process, uid/gid, rlimit, and poll APIs not provided by MinGW"
    SKIPPED_EXTENSIONS+=("pg_cron: disabled on MinGW due to POSIX-only scheduler/process APIs")
    return 0
  fi

  make_pgxs_install pg_cron "${EXT_SOURCE_DIR}/pg_cron"
}

build_pg_net() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping pg_net: upstream sources require kqueue/sys/event.h style event loop APIs unavailable on MinGW"
    SKIPPED_EXTENSIONS+=("pg_net: disabled on MinGW due to missing sys/event.h and event loop support")
    return 0
  fi

  make_pgxs_install pg_net "${EXT_SOURCE_DIR}/pg_net"
}

build_pgsql_http() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping pgsql-http: upstream sources require POSIX regex headers unavailable on MinGW"
    SKIPPED_EXTENSIONS+=("pgsql-http: disabled on MinGW due to missing regex.h/POSIX regex support")
    return 0
  fi

  make_pgxs_install pgsql-http "${EXT_SOURCE_DIR}/pgsql-http" \
    CURL_CONFIG="${SDK_PREFIX}/bin/curl-config" \
    PG_CPPFLAGS="-I${SDK_PREFIX}/include" \
    SHLIB_LINK="-L${SDK_PREFIX}/lib -lcurl"
}

build_pgaudit() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch "${EXT_SOURCE_DIR}/pgaudit" "/work/mount_root/patch/pgaudit-18.0-mingw-no-win32-resource.patch"
  fi

  make_pgxs_install pgaudit "${EXT_SOURCE_DIR}/pgaudit"
}

build_set_user() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch "${EXT_SOURCE_DIR}/set_user" "/work/mount_root/patch/set_user-REL4_2_0-mingw-no-win32-resource.patch"
  fi

  make_pgxs_install set_user "${EXT_SOURCE_DIR}/set_user"
}

build_pg_stat_monitor() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping pg_stat_monitor: upstream supported platforms are Linux distributions; MinGW crashes under PostgreSQL EXEC_BACKEND"
    SKIPPED_EXTENSIONS+=("pg_stat_monitor: disabled on MinGW because upstream supports Linux platforms and the extension crashes under PostgreSQL EXEC_BACKEND")
    return 0
  fi

  apply_source_patch "${EXT_SOURCE_DIR}/pg_stat_monitor" "/work/mount_root/patch/pg_stat_monitor-2.3.2-pg18-procnumber.patch"
  grep -q "pgstat_get_beentry_by_proc_number(MyProcNumber)" "${EXT_SOURCE_DIR}/pg_stat_monitor/pg_stat_monitor.c" \
    || die "pg_stat_monitor PG18 procnumber patch did not apply correctly"

  make_pgxs_install pg_stat_monitor "${EXT_SOURCE_DIR}/pg_stat_monitor"
}

build_age() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping age: upstream Apache AGE sources are not currently MinGW-compatible"
    SKIPPED_EXTENSIONS+=("age: upstream Apache AGE sources conflict with MinGW/Win32 headers and missing clock_gettime")
    return 0
  fi

  make_pgxs_install age "${EXT_SOURCE_DIR}/age"
}

build_timescaledb() {
  local source_dir="${EXT_SOURCE_DIR}/timescaledb"
  local build_dir="${EXT_BUILD_DIR}/timescaledb"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping timescaledb: Windows/MinGW packaging is not supported in this distribution yet"
    SKIPPED_EXTENSIONS+=("timescaledb: disabled on MinGW pending upstream/runtime packaging support")
    return 0
  fi

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

build_pgroonga() {
  local source_dir="${EXT_SOURCE_DIR}/pgroonga"

  apply_source_patch "$source_dir" "/work/mount_root/patch/pgroonga-4.0.6-mingw-avoid-msvc-flags.patch"
  meson_extension_install pgroonga "$source_dir" \
    -Dpg_config="$PG_CONFIG" \
    -Dinstall_to_postgresql=true \
    -Dtest=false
}

build_plv8() {
  local source_dir="${EXT_SOURCE_DIR}/plv8"

  apply_source_patch "$source_dir" "/work/mount_root/patch/plv8-3.2.4-external-v8-prefix.patch"
  make_pgxs_install plv8 "$source_dir" \
    V8_PREFIX="$SDK_PREFIX" \
    CC="$CXX" \
    CXX="$CXX" \
    CPP="$CXX -E"
}

build_pgmq() {
  make_pgxs_install pgmq "${EXT_SOURCE_DIR}/pgmq/pgmq-extension"
}

build_pgbouncer() {
  local source_dir="${EXT_SOURCE_DIR}/pgbouncer"
  local build_dir="${EXT_BUILD_DIR}/pgbouncer"
  local pgbouncer_libevent_cflags="-I${SDK_PREFIX}/include"
  local pgbouncer_libevent_libs="-L${SDK_PREFIX}/lib -levent"
  local pgbouncer_extra_libs=""

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cp -a "${source_dir}/." "$build_dir/"

  if extension_env pkg-config --exists libevent; then
    pgbouncer_libevent_cflags="$(extension_env pkg-config --cflags libevent)"
    pgbouncer_libevent_libs="$(extension_env pkg-config --libs libevent)"
  fi
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    pgbouncer_libevent_libs="-L${SDK_PREFIX}/lib -levent_core -levent"
    pgbouncer_extra_libs="-lws2_32 -liphlpapi -lshell32 -ladvapi32"
  fi

  log "Configuring tool: pgbouncer"
  (
    cd "$build_dir"
    extension_env \
      LIBEVENT_CFLAGS="$pgbouncer_libevent_cflags" \
      LIBEVENT_LIBS="${pgbouncer_libevent_libs} ${pgbouncer_extra_libs}" \
      LIBS="${pgbouncer_libevent_libs} ${pgbouncer_extra_libs} ${LIBS:-}" \
      ./configure \
      --build="${BUILD_TRIPLE}" \
      --host="$CONFIGURE_HOST_TRIPLE" \
      --prefix="$SDK_PREFIX" \
      --with-openssl="$SDK_PREFIX" \
      --without-cares
    extension_env \
      LIBEVENT_CFLAGS="$pgbouncer_libevent_cflags" \
      LIBEVENT_LIBS="${pgbouncer_libevent_libs} ${pgbouncer_extra_libs}" \
      LIBS="${pgbouncer_libevent_libs} ${pgbouncer_extra_libs} ${LIBS:-}" \
      make -j "$JOBS" "pgbouncer${EXEEXT}"
    install -d "${SDK_PREFIX}/bin" "${SDK_PREFIX}/etc/pgbouncer"
    install -m 755 "pgbouncer${EXEEXT}" "${SDK_PREFIX}/bin/"
    install -m 644 etc/pgbouncer.ini etc/userlist.txt "${SDK_PREFIX}/etc/pgbouncer/"
  )
  [[ -x "${SDK_PREFIX}/bin/pgbouncer${EXEEXT}" ]] || die "pgbouncer install did not produce ${SDK_PREFIX}/bin/pgbouncer${EXEEXT}"
  INSTALLED_TOOLS+=(pgbouncer)
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

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch "${EXT_SOURCE_DIR}/pg_repack" "/work/mount_root/patch/pg_repack-1.5.3-mingw-sleep-signature.patch"
  fi

  make_pgxs_install pg_repack "${EXT_SOURCE_DIR}/pg_repack"
}

build_mysql_fdw() {
  [[ -f "${SDK_PREFIX}/include/mariadb/mysql.h" ]] || die "missing MariaDB/MySQL headers for mysql_fdw"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    if [[ ! -e "${SDK_PREFIX}/lib/libmysqlclient.dll.a" && -e "${SDK_PREFIX}/lib/mariadb/libmysqlclient.dll.a" ]]; then
      ln -s "mariadb/libmysqlclient.dll.a" "${SDK_PREFIX}/lib/libmysqlclient.dll.a"
    fi
    if [[ ! -e "${SDK_PREFIX}/lib/libmysqlclient.dll.a" && -e "${SDK_PREFIX}/lib/mariadb/libmariadb.dll.a" ]]; then
      ln -s "mariadb/libmariadb.dll.a" "${SDK_PREFIX}/lib/libmysqlclient.dll.a"
    fi
    if [[ ! -e "${SDK_PREFIX}/lib/libmysqlclient.dll.a" && -e "${SDK_PREFIX}/lib/mariadb/liblibmariadb.dll.a" ]]; then
      ln -s "mariadb/liblibmariadb.dll.a" "${SDK_PREFIX}/lib/libmysqlclient.dll.a"
    fi
    if [[ ! -e "${SDK_PREFIX}/lib/libmariadb.dll.a" && -e "${SDK_PREFIX}/lib/mariadb/libmariadb.dll.a" ]]; then
      ln -s "mariadb/libmariadb.dll.a" "${SDK_PREFIX}/lib/libmariadb.dll.a"
    fi
    if [[ ! -e "${SDK_PREFIX}/lib/libmariadb.dll.a" && -e "${SDK_PREFIX}/lib/mariadb/liblibmariadb.dll.a" ]]; then
      ln -s "mariadb/liblibmariadb.dll.a" "${SDK_PREFIX}/lib/libmariadb.dll.a"
    fi
    [[ -e "${SDK_PREFIX}/lib/libmysqlclient.dll.a" ]] || die "missing MariaDB/MySQL import library for mysql_fdw"
    apply_source_patch "${EXT_SOURCE_DIR}/mysql_fdw" "/work/mount_root/patch/mysql_fdw-2_9_3-mingw-dlopen.patch"
  else
    if [[ ! -e "${SDK_PREFIX}/lib/libmysqlclient.so" && -e "${SDK_PREFIX}/lib/mariadb/libmysqlclient.so" ]]; then
      ln -s "mariadb/libmysqlclient.so" "${SDK_PREFIX}/lib/libmysqlclient.so"
    fi
    if [[ ! -e "${SDK_PREFIX}/lib/libmariadb.so.3" && -e "${SDK_PREFIX}/lib/mariadb/libmariadb.so.3" ]]; then
      ln -s "mariadb/libmariadb.so.3" "${SDK_PREFIX}/lib/libmariadb.so.3"
    fi
  fi

  cat >"${BUILD_TOOLS}/mariadb_config" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
  --include|--cflags)
    printf '%s\n' "-I${SDK_PREFIX}/include/mariadb -I${SDK_PREFIX}/include/mariadb/mysql"
    ;;
  --libs|--libs_r)
    printf '%s\n' "-L${SDK_PREFIX}/lib -L${SDK_PREFIX}/lib/mariadb -lmysqlclient"
    ;;
  --version)
    printf '%s\n' "10.8.8"
    ;;
  *)
    printf '%s\n' ""
    ;;
esac
EOF
  chmod +x "${BUILD_TOOLS}/mariadb_config"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    make_pgxs_install mysql_fdw "${EXT_SOURCE_DIR}/mysql_fdw" \
      MYSQL_CONFIG="${BUILD_TOOLS}/mariadb_config" \
      MYSQL_LIBNAME="libmariadb-3.dll"
  else
    make_pgxs_install mysql_fdw "${EXT_SOURCE_DIR}/mysql_fdw" \
      MYSQL_CONFIG="${BUILD_TOOLS}/mariadb_config"
  fi
}

build_tds_fdw() {
  [[ -f "${SDK_PREFIX}/include/sybfront.h" ]] || die "missing FreeTDS sybfront.h for tds_fdw"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    [[ -f "${SDK_PREFIX}/lib/libsybdb.dll.a" ]] || die "missing FreeTDS libsybdb.dll.a for tds_fdw"
    apply_source_patch "${EXT_SOURCE_DIR}/tds_fdw" "/work/mount_root/patch/tds_fdw-2.0.5-mingw-win32-headers.patch"
    make_pgxs_install tds_fdw "${EXT_SOURCE_DIR}/tds_fdw" \
      TDS_INCLUDE="-I${SDK_PREFIX}/include" \
      SHLIB_LINK="-L${SDK_PREFIX}/lib -lsybdb -lpostgres"
    return
  else
    [[ -f "${SDK_PREFIX}/lib/libsybdb.so" ]] || die "missing FreeTDS libsybdb.so for tds_fdw"
  fi

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
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libmongoc-1.0.dll.a' | grep -q . || die "missing libmongoc-1.0.dll.a for mongo_fdw"
    find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libbson-1.0.dll.a' | grep -q . || die "missing libbson-1.0.dll.a for mongo_fdw"
    [[ -f "${SDK_PREFIX}/lib/libjson-c.dll.a" ]] || die "missing libjson-c.dll.a for mongo_fdw"
  else
    find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libmongoc-1.0.so*' | grep -q . || die "missing libmongoc-1.0 for mongo_fdw"
    find "${SDK_PREFIX}/lib" \( -type f -o -type l \) -name 'libbson-1.0.so*' | grep -q . || die "missing libbson-1.0 for mongo_fdw"
    [[ -f "${SDK_PREFIX}/lib/libjson-c.so" ]] || die "missing libjson-c for mongo_fdw"
  fi

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    make_pgxs_install mongo_fdw "${EXT_SOURCE_DIR}/mongo_fdw" \
      LIBJSON_OBJS= \
      PG_CPPFLAGS="--std=c99 -I${SDK_PREFIX}/include/libmongoc-1.0 -I${SDK_PREFIX}/include/libbson-1.0 -I${SDK_PREFIX}/include/json-c -I${SDK_PREFIX}/include" \
      SHLIB_LINK="-L${SDK_PREFIX}/lib -lmongoc-1.0 -lbson-1.0 -ljson-c -lpostgres"
    return
  fi

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
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    make_pgxs_install oracle_fdw "${EXT_SOURCE_DIR}/oracle_fdw" \
      ORACLE_SHLIB=oci \
      SHLIB_LINK="-L${ORACLE_HOME} -L${ORACLE_HOME}/bin -L${ORACLE_HOME}/lib -loci -lpostgres"
    rm -rf "${SDK_PREFIX}/instantclient" "${SDK_PREFIX}/lib/libclntsh"* "${SDK_PREFIX}/lib/libocci"*
    return
  fi
  make_pgxs_install oracle_fdw "${EXT_SOURCE_DIR}/oracle_fdw"
  rm -rf "${SDK_PREFIX}/instantclient" "${SDK_PREFIX}/lib/libclntsh"* "${SDK_PREFIX}/lib/libocci"*
}

build_db2_fdw() {
  [[ -n "${DB2_HOME:-}" ]] || {
    log "Skipping db2_fdw: DB2 CLI directory was not provided"
    SKIPPED_EXTENSIONS+=("db2_fdw: DB2 CLI directory was not provided")
    return 0
  }
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch "${EXT_SOURCE_DIR}/db2_fdw" "/work/mount_root/patch/db2_fdw-18.1.2-mingw-sal-annotations.patch"
    make_pgxs_install db2_fdw "${EXT_SOURCE_DIR}/db2_fdw" \
      PG_CPPFLAGS="-g -include ./include/db2_fdw_mingw_compat.h -I${DB2_HOME}/include -I./include" \
      SHLIB_LINK="-L${DB2_HOME}/lib -L${DB2_HOME}/bin -ldb2 -lpostgres"
    rm -f "${SDK_PREFIX}/lib/libdb2."*
    return
  fi
  make_pgxs_install db2_fdw "${EXT_SOURCE_DIR}/db2_fdw" \
    PG_CPPFLAGS="-g -fPIC -I${DB2_HOME}/include -I./include" \
    SHLIB_LINK="-fPIC -L${DB2_HOME}/lib -L${DB2_HOME}/lib64 -L${DB2_HOME}/bin -ldb2"
  rm -f "${SDK_PREFIX}/lib/libdb2."*
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete 2>/dev/null || true
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete 2>/dev/null || true
  else
    find "${SDK_PREFIX}/lib" -type f -name '*.a' -delete 2>/dev/null || true
  fi
}

copy_mingw_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
}

validate_mingw_pl_languages() {
  local required_path=""

  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  for required_path in \
    "${SDK_PREFIX}/lib/plperl.dll" \
    "${SDK_PREFIX}/lib/plpython3.dll" \
    "${SDK_PREFIX}/share/extension/plperl.control" \
    "${SDK_PREFIX}/share/extension/plpython3u.control" \
    "${SDK_PREFIX}/bin/perl542.dll" \
    "${SDK_PREFIX}/bin/libpython3.14.dll"; do
    [[ -e "$required_path" ]] || die "MinGW distribution package is missing PL runtime path: ${required_path}"
  done
}

write_distribution_readme() {
  local extension_lines=""
  local tool_lines=""
  local skipped_lines=""
  local extension_name=""
  local tool_name=""

  for extension_name in "${INSTALLED_EXTENSIONS[@]}"; do
    extension_lines+="- ${extension_name}"$'\n'
  done
  for tool_name in "${INSTALLED_TOOLS[@]}"; do
    tool_lines+="- ${tool_name}"$'\n'
  done
  [[ -n "$tool_lines" ]] || tool_lines="- none"$'\n'
  for extension_name in "${SKIPPED_EXTENSIONS[@]}"; do
    skipped_lines+="- ${extension_name}"$'\n'
  done
  [[ -n "$skipped_lines" ]] || skipped_lines="- none"$'\n'

  render_template "/work/mount_root/templates/README.postgresql18-dist.in" \
    "${SDK_PREFIX}/README.postgresql18-dist" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "POSTGRESQL_VERSION=${POSTGRESQL_VERSION}" \
    "INSTALLED_EXTENSIONS=${extension_lines}" \
    "INSTALLED_TOOLS=${tool_lines}" \
    "SKIPPED_EXTENSIONS=${skipped_lines}"
}

write_systemd_templates() {
  local systemd_dir="${SDK_PREFIX}/share/systemd"
  local python_dir=""
  local python_path=""
  local perl_archlib=""
  local perl_privlib=""
  local perl_path=""
  local tcl_library=""

  [[ "${TARGET_KIND}" == "linux" ]] || return 0

  mkdir -p "${systemd_dir}"

  python_dir="$(
    find "${SDK_PREFIX}/lib" -maxdepth 1 -type d -name 'python3.*' \
      | sort \
      | head -n 1
  )"
  if [[ -n "${python_dir}" ]]; then
    python_path="${python_dir}"
    [[ -d "${python_dir}/lib-dynload" ]] && python_path="${python_path}:${python_dir}/lib-dynload"
    [[ -d "${python_dir}/site-packages" ]] && python_path="${python_path}:${python_dir}/site-packages"
  fi

  perl_archlib="$(
    find "${SDK_PREFIX}/lib" -path '*/Config_heavy.pl' -type f -print 2>/dev/null \
      | sort \
      | head -n 1
  )"
  if [[ -n "${perl_archlib}" ]]; then
    perl_archlib="$(dirname "${perl_archlib}")"
    perl_privlib="$(dirname "${perl_archlib}")"
    perl_path="${perl_archlib}:${perl_privlib}"
  fi

  tcl_library="$(
    find "${SDK_PREFIX}/lib" -maxdepth 1 -type d -name 'tcl8.*' \
      | sort \
      | head -n 1
  )"

  render_template "/work/mount_root/templates/postgresql18-dist.env.in" \
    "${systemd_dir}/postgresql18-dist.env" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "POSTGRESQL18_DIST_PYTHONPATH=${python_path}" \
    "POSTGRESQL18_DIST_PERL5LIB=${perl_path}" \
    "POSTGRESQL18_DIST_TCL_LIBRARY=${tcl_library}"

  render_template "/work/mount_root/templates/postgresql18-dist.service.in" \
    "${systemd_dir}/postgresql18-dist.service" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}"
}

write_service_installers() {
  render_template "/work/mount_root/templates/install_service.sh.in" \
    "${SDK_PREFIX}/install_service.sh"
  chmod +x "${SDK_PREFIX}/install_service.sh"

  render_template "/work/mount_root/templates/install_service.cmd.in" \
    "${SDK_PREFIX}/install_service.cmd"
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

write_windres_wrapper() {
  local wrapper_path="$1"
  local real_windres="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

exec "${real_windres}" \
  --target="${TARGET_TRIPLE}" \
  -I"${SYSROOT}/usr/${TARGET_TRIPLE}/include" \
  -I"${SDK_PREFIX}/include" \
  "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_common_build_tool_wrappers() {
  local tool_name=""
  local real_tool=""

  for tool_name in perl python python3 curl; do
    real_tool="$(command -v "$tool_name" 2>/dev/null || true)"
    if [[ -n "$real_tool" ]]; then
      write_exec_wrapper "${BUILD_TOOLS}/${tool_name}" "$real_tool"
    fi
  done
}

write_cross_pg_config_wrapper() {
  local wrapper_path="${BUILD_TOOLS}/pg_config"
  local configure_host_triple="$CONFIGURE_HOST_TRIPLE"
  local cflags_sl="-fPIC"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cflags_sl=""
  fi

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

prefix="${SDK_PREFIX}"
cc="${CC}"
cppflags="${COMMON_CPPFLAGS}"
cflags="${COMMON_CFLAGS}"
ldflags="${COMMON_LDFLAGS}"

if [[ "\$#" -eq 0 ]]; then
  set -- --help
fi

for option in "\$@"; do
  case "\$option" in
    --bindir) printf '%s\n' "\${prefix}/bin" ;;
    --docdir) printf '%s\n' "\${prefix}/share/doc" ;;
    --htmldir) printf '%s\n' "\${prefix}/share/doc" ;;
    --includedir) printf '%s\n' "\${prefix}/include" ;;
    --pkgincludedir) printf '%s\n' "\${prefix}/include" ;;
    --includedir-server) printf '%s\n' "\${prefix}/include/server" ;;
    --libdir) printf '%s\n' "\${prefix}/lib" ;;
    --pkglibdir) printf '%s\n' "\${prefix}/lib" ;;
    --localedir) printf '%s\n' "\${prefix}/share/locale" ;;
    --mandir) printf '%s\n' "\${prefix}/share/man" ;;
    --sharedir) printf '%s\n' "\${prefix}/share" ;;
    --sysconfdir) printf '%s\n' "\${prefix}/etc" ;;
    --pgxs) printf '%s\n' "\${prefix}/lib/pgxs/src/makefiles/pgxs.mk" ;;
    --cc) printf '%s\n' "\${cc}" ;;
    --cppflags) printf '%s\n' "\${cppflags}" ;;
    --cflags) printf '%s\n' "\${cflags}" ;;
    --cflags_sl) printf '%s\n' "${cflags_sl}" ;;
    --ldflags) printf '%s\n' "\${ldflags}" ;;
    --ldflags_ex) printf '%s\n' "\${ldflags}" ;;
    --ldflags_sl) printf '%s\n' "\${ldflags}" ;;
    --libs) printf '%s\n' "" ;;
    --version) printf '%s\n' "PostgreSQL ${POSTGRESQL_VERSION}" ;;
    --configure) printf '%s\n' "--prefix=\${prefix} --host=${configure_host_triple}" ;;
    --help)
      cat <<'HELP'
Usage: pg_config [OPTION]
Cross-build wrapper for the target PostgreSQL prefix.
HELP
      ;;
    *)
      echo "pg_config wrapper: unsupported option: \${option}" >&2
      exit 1
      ;;
  esac
done
EOF
  chmod +x "$wrapper_path"
}

write_meson_cross_file() {
  local cross_file="${BUILD_TOOLS}/meson-${TARGET_TRIPLE}.ini"
  local cpu_family="$ARCH"
  local meson_system="linux"
  local meson_extra_c_args=", '-I${SDK_PREFIX}/include/ncursesw', '-I${SDK_PREFIX}/include/libxml2'"
  local meson_extra_link_args=""

  case "$ARCH" in
    x86_64) cpu_family="x86_64" ;;
    aarch64) cpu_family="aarch64" ;;
    riscv64) cpu_family="riscv64" ;;
    loongarch64) cpu_family="loongarch64" ;;
  esac

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    meson_system="windows"
    meson_extra_c_args=""
  else
    meson_extra_link_args+=" , '-Wl,-rpath,${SDK_PREFIX}/lib'"
    meson_extra_link_args+=" , '-Wl,-rpath-link,${SDK_PREFIX}/lib'"
    meson_extra_link_args+=" , '-Wl,-rpath-link,${SYSROOT}/usr/lib'"
    meson_extra_link_args+=" , '-Wl,-rpath-link,${SYSROOT}/usr/lib64'"
    meson_extra_link_args+=" , '-Wl,-rpath-link,${SYSROOT}/lib'"
    meson_extra_link_args+=" , '-Wl,-rpath-link,${SYSROOT}/lib64'"
  fi

  render_template "/work/mount_root/templates/meson-cross.ini.in" "$cross_file" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR:-${LLVM_ROOT}/bin/llvm-ar}" \
    "STRIP=${STRIP:-${LLVM_ROOT}/bin/llvm-strip}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}" \
    "MESON_SYSTEM=${meson_system}" \
    "MESON_CPU_FAMILY=${cpu_family}" \
    "MESON_CPU=${ARCH}" \
    "MESON_EXTRA_C_ARGS=${meson_extra_c_args}" \
    "MESON_EXTRA_LINK_ARGS=${meson_extra_link_args}"

  MESON_CROSS_FILE="$cross_file"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-${TARGET_TRIPLE:-}}"
BUILD_TRIPLE="${BUILD_TRIPLE:-x86_64-pc-linux-gnu}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/postgresql18_dist-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
ORACLE_SDK_ARCHIVE="${ORACLE_SDK_ARCHIVE:-}"
ORACLE_BASIC_ARCHIVE="${ORACLE_BASIC_ARCHIVE:-}"
DB2_CLI_ARCHIVE="${DB2_CLI_ARCHIVE:-}"
DB2_CLI_DIR="${DB2_CLI_DIR:-}"
WITH_FDW="${WITH_FDW:-1}"
WITH_ORACLE_FDW="${WITH_ORACLE_FDW:-1}"
WITH_DB2_FDW="${WITH_DB2_FDW:-1}"
WITH_PLJAVA="${WITH_PLJAVA:-0}"
WITH_PG_TDE="${WITH_PG_TDE:-1}"
WITH_PG_REPACK="${WITH_PG_REPACK:-1}"
WITH_PLV8="${WITH_PLV8:-1}"

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
PGBOUNCER_VERSION="${PGBOUNCER_VERSION:-1.25.2}"
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

case "$TARGET_KIND:$ARCH" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "container supports Linux x86_64/aarch64/riscv64/loongarch64 and MinGW x86_64 package targets; got ${TARGET_KIND}:${ARCH}" ;;
esac
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

EXEEXT=""
MESON_SYSTEM="linux"
MESON_CPU_FAMILY="$ARCH"
MESON_CPU="$ARCH"
COMMON_CPPFLAGS="-D_GNU_SOURCE -I${SDK_PREFIX}/include"
COMMON_PG_CPPFLAGS="-I${SDK_PREFIX}/include"
COMMON_CFLAGS="-I${SDK_PREFIX}/include -fPIC"
COMMON_CXXFLAGS="-I${SDK_PREFIX}/include -fPIC"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib -Wl,-rpath,${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib"

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    COMMON_CPPFLAGS+=" -I${SDK_PREFIX}/include/ncursesw -I${SDK_PREFIX}/include/libxml2"
    COMMON_PG_CPPFLAGS+=" -I${SDK_PREFIX}/include/ncursesw -I${SDK_PREFIX}/include/libxml2"
    COMMON_CFLAGS+=" -I${SDK_PREFIX}/include/ncursesw -I${SDK_PREFIX}/include/libxml2"
    COMMON_CXXFLAGS+=" -I${SDK_PREFIX}/include/ncursesw -I${SDK_PREFIX}/include/libxml2"
    COMMON_LDFLAGS+=" -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
    ;;
  mingw)
    EXEEXT=".exe"
    MESON_SYSTEM="windows"
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
    CONFIGURE_HOST_TRIPLE="x86_64-w64-mingw32"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    COMMON_CPPFLAGS+=" -I${SDK_PREFIX}/include/libxml2"
    COMMON_PG_CPPFLAGS+=" -I${SDK_PREFIX}/include/libxml2"
    COMMON_CFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/libxml2"
    COMMON_CXXFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/libxml2"
    COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
    ;;
esac

TARGET_PG_CONFIG="${SDK_PREFIX}/bin/pg_config${EXEEXT}"
[[ -x "$TARGET_PG_CONFIG" ]] || die "missing pg_config: ${TARGET_PG_CONFIG}"
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TOOLS="${BUILD_DIR}/tools"
EXT_SOURCE_DIR="${BUILD_DIR}/src/postgresql18_dist"
EXT_BUILD_DIR="${BUILD_DIR}/build/postgresql18_dist"
mkdir -p "$BUILD_TOOLS" "$EXT_SOURCE_DIR" "$EXT_BUILD_DIR"
write_noop_ldconfig_wrapper "$BUILD_TOOLS"
write_common_build_tool_wrappers

CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
WINDRES="${WINDRES:-${LLVM_ROOT}/bin/llvm-windres}"
[[ -x "$CC" ]] || CC="${LLVM_ROOT}/bin/clang"
[[ -x "$CXX" ]] || CXX="${LLVM_ROOT}/bin/clang++"
[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$CC" ]] || die "missing C compiler"
[[ -x "$CXX" ]] || die "missing C++ compiler"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  [[ -x "$WINDRES" ]] || WINDRES="$(command -v llvm-windres 2>/dev/null || true)"
  [[ -n "$WINDRES" && -x "$WINDRES" ]] || die "missing windres tool for mingw build"
  write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "$WINDRES"
  WINDRES="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
fi
write_cross_pg_config_wrapper
write_meson_cross_file
PG_CONFIG="${BUILD_TOOLS}/pg_config"

export PATH="${BUILD_TOOLS}:${SDK_PREFIX}/bin:${LLVM_ROOT}/bin:${PATH}"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  export LD_LIBRARY_PATH="${SDK_PREFIX}/bin:${SDK_PREFIX}/lib:${SDK_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
else
  export LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${SDK_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
fi
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
download_archive "https://www.pgbouncer.org/downloads/files/${PGBOUNCER_VERSION}/pgbouncer-${PGBOUNCER_VERSION}.tar.gz" "pgbouncer-${PGBOUNCER_VERSION}.tar.gz"
if is_enabled "$WITH_PLV8"; then
  download_archive "https://github.com/plv8/plv8/archive/refs/tags/v${PLV8_VERSION}.tar.gz" "plv8-${PLV8_VERSION}.tar.gz"
fi
download_archive "https://github.com/timescale/timescaledb/archive/refs/tags/${TIMESCALEDB_VERSION}.tar.gz" "timescaledb-${TIMESCALEDB_VERSION}.tar.gz"
download_archive "https://github.com/pgaudit/pgaudit/archive/refs/tags/${PGAUDIT_VERSION}.tar.gz" "pgaudit-${PGAUDIT_VERSION}.tar.gz"
download_archive "https://github.com/percona/pg_stat_monitor/archive/refs/tags/${PG_STAT_MONITOR_VERSION}.tar.gz" "pg_stat_monitor-${PG_STAT_MONITOR_VERSION}.tar.gz"
if is_enabled "$WITH_PG_TDE"; then
  download_archive "https://github.com/percona/pg_tde/archive/refs/tags/${PG_TDE_VERSION}.tar.gz" "pg_tde-${PG_TDE_VERSION}.tar.gz"
fi
download_archive "https://github.com/pgaudit/set_user/archive/refs/tags/${SET_USER_VERSION}.tar.gz" "set_user-${SET_USER_VERSION}.tar.gz"
if is_enabled "$WITH_PG_REPACK"; then
  download_archive "https://github.com/reorg/pg_repack/archive/refs/tags/ver_${PG_REPACK_VERSION}.tar.gz" "pg_repack-${PG_REPACK_VERSION}.tar.gz"
fi
if is_enabled "$WITH_FDW"; then
  download_archive "https://github.com/pg-redis-fdw/redis_fdw/archive/refs/heads/REL_18_STABLE.zip" "redis_fdw-REL_18_STABLE.zip"
  download_archive "https://github.com/EnterpriseDB/mysql_fdw/archive/refs/tags/REL-${MYSQL_FDW_VERSION}.tar.gz" "mysql_fdw-${MYSQL_FDW_VERSION}.tar.gz"
  download_archive "https://github.com/tds-fdw/tds_fdw/archive/refs/tags/v${TDS_FDW_VERSION}.tar.gz" "tds_fdw-${TDS_FDW_VERSION}.tar.gz"
  download_archive "https://github.com/pgspider/sqlite_fdw/archive/refs/tags/v${SQLITE_FDW_VERSION}.tar.gz" "sqlite_fdw-${SQLITE_FDW_VERSION}.tar.gz"
  download_archive "https://github.com/EnterpriseDB/mongo_fdw/archive/refs/tags/REL-${MONGO_FDW_VERSION}.tar.gz" "mongo_fdw-${MONGO_FDW_VERSION}.tar.gz"
  if is_enabled "$WITH_ORACLE_FDW"; then
    download_archive "https://github.com/laurenz/oracle_fdw/archive/refs/tags/ORACLE_FDW_${ORACLE_FDW_VERSION}.tar.gz" "oracle_fdw-${ORACLE_FDW_VERSION}.tar.gz"
  fi
  if is_enabled "$WITH_DB2_FDW"; then
    download_archive "https://github.com/pg-fdw/db2_fdw/releases/download/${DB2_FDW_VERSION}/db2_fdw-${DB2_FDW_VERSION}.zip" "db2_fdw-${DB2_FDW_VERSION}.zip"
  fi
fi

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
extract_source "${EXT_SOURCE_DIR}/pgbouncer" "pgbouncer-${PGBOUNCER_VERSION}.tar.gz" "configure"
if is_enabled "$WITH_PLV8"; then
  extract_source "${EXT_SOURCE_DIR}/plv8" "plv8-${PLV8_VERSION}.tar.gz" "Makefile"
fi
extract_source "${EXT_SOURCE_DIR}/timescaledb" "timescaledb-${TIMESCALEDB_VERSION}.tar.gz" "CMakeLists.txt"
extract_source "${EXT_SOURCE_DIR}/pgaudit" "pgaudit-${PGAUDIT_VERSION}.tar.gz" "Makefile"
extract_source "${EXT_SOURCE_DIR}/pg_stat_monitor" "pg_stat_monitor-${PG_STAT_MONITOR_VERSION}.tar.gz" "Makefile"
if is_enabled "$WITH_PG_TDE"; then
  extract_source "${EXT_SOURCE_DIR}/pg_tde" "pg_tde-${PG_TDE_VERSION}.tar.gz" "Makefile"
fi
extract_source "${EXT_SOURCE_DIR}/set_user" "set_user-${SET_USER_VERSION}.tar.gz" "Makefile"
if is_enabled "$WITH_PG_REPACK"; then
  extract_source "${EXT_SOURCE_DIR}/pg_repack" "pg_repack-${PG_REPACK_VERSION}.tar.gz" "Makefile"
fi
if is_enabled "$WITH_FDW"; then
  extract_source "${EXT_SOURCE_DIR}/redis_fdw" "redis_fdw-REL_18_STABLE.zip" "Makefile"
  extract_source "${EXT_SOURCE_DIR}/mysql_fdw" "mysql_fdw-${MYSQL_FDW_VERSION}.tar.gz" "Makefile"
  extract_source "${EXT_SOURCE_DIR}/tds_fdw" "tds_fdw-${TDS_FDW_VERSION}.tar.gz" "Makefile"
  extract_source "${EXT_SOURCE_DIR}/sqlite_fdw" "sqlite_fdw-${SQLITE_FDW_VERSION}.tar.gz" "Makefile"
  extract_source "${EXT_SOURCE_DIR}/mongo_fdw" "mongo_fdw-${MONGO_FDW_VERSION}.tar.gz" "Makefile"
  if is_enabled "$WITH_ORACLE_FDW"; then
    extract_source "${EXT_SOURCE_DIR}/oracle_fdw" "oracle_fdw-${ORACLE_FDW_VERSION}.tar.gz" "Makefile"
  fi
  if is_enabled "$WITH_DB2_FDW"; then
    extract_source "${EXT_SOURCE_DIR}/db2_fdw" "db2_fdw-${DB2_FDW_VERSION}.zip" "Makefile"
  fi
fi

INSTALLED_EXTENSIONS=()
INSTALLED_TOOLS=()
SKIPPED_EXTENSIONS=()
ORACLE_HOME=""
if is_enabled "$WITH_PLJAVA"; then
  SKIPPED_EXTENSIONS+=("pljava: disabled; PL/Java build is not implemented in this package yet")
else
  SKIPPED_EXTENSIONS+=("pljava: disabled by package configuration")
fi
if is_enabled "$WITH_FDW"; then
  if is_enabled "$WITH_ORACLE_FDW"; then
    install_oracle_client_for_build
  else
    SKIPPED_EXTENSIONS+=("oracle_fdw: disabled by package configuration")
  fi
  if is_enabled "$WITH_DB2_FDW"; then
    install_db2_cli_for_build
  else
    SKIPPED_EXTENSIONS+=("db2_fdw: disabled by package configuration")
  fi
else
  SKIPPED_EXTENSIONS+=("fdw extensions: disabled by package configuration")
  SKIPPED_EXTENSIONS+=("oracle_fdw: disabled by package configuration")
  SKIPPED_EXTENSIONS+=("db2_fdw: disabled by package configuration")
fi

make_pgxs_install vector "${EXT_SOURCE_DIR}/pgvector" OPTFLAGS=
build_age
build_pgroonga
build_postgis
build_pgrouting
build_pg_cron
make_pgxs_install pg_partman "${EXT_SOURCE_DIR}/pg_partman"
build_pg_net
build_pgsql_http
build_pgmq
build_pgbouncer
if is_enabled "$WITH_PLV8"; then
  build_plv8
else
  SKIPPED_EXTENSIONS+=("plv8: disabled by package configuration")
fi
build_timescaledb
build_pgaudit
build_pg_stat_monitor
if is_enabled "$WITH_PG_TDE"; then
  build_pg_tde
else
  SKIPPED_EXTENSIONS+=("pg_tde: disabled by package configuration")
fi
build_set_user
if is_enabled "$WITH_PG_REPACK"; then
  build_pg_repack
else
  SKIPPED_EXTENSIONS+=("pg_repack: disabled by package configuration")
fi
if is_enabled "$WITH_FDW"; then
  make_pgxs_install redis_fdw "${EXT_SOURCE_DIR}/redis_fdw"
  build_mysql_fdw
  build_tds_fdw
  build_sqlite_fdw
  build_mongo_fdw
  if is_enabled "$WITH_ORACLE_FDW"; then
    build_oracle_fdw
  fi
  if is_enabled "$WITH_DB2_FDW"; then
    build_db2_fdw
  fi
fi

remove_static_libraries
copy_mingw_dlls_to_bin
validate_mingw_pl_languages
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
write_distribution_readme
write_systemd_templates
write_service_installers

log "PostgreSQL 18 distribution package ready: ${SDK_PREFIX}"
