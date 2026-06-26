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
  ./packages/postgresql18_dist/test_package.sh --target=<target> --package-dir=<dir>
  ./packages/postgresql18_dist/test_package.sh --target=<target> --archive=<tar.xz>

Options:
  --target=<target>       PostgreSQL 18 dist target
  --arch=<target>         Alias for --target
  --package-dir=<dir>     Extracted package prefix
  --archive=<tar.xz>      Package archive to extract and test
  -h, --help              Show this help
EOF
}

TARGET=""
PACKAGE_DIR=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    --package-dir=*) PACKAGE_DIR="${1#*=}" ;;
    --package-dir)
      shift
      [[ $# -gt 0 ]] || die "--package-dir requires a value"
      PACKAGE_DIR="$1"
      ;;
    --archive=*) ARCHIVE="${1#*=}" ;;
    --archive)
      shift
      [[ $# -gt 0 ]] || die "--archive requires a value"
      ARCHIVE="$1"
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

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "PostgreSQL 18 dist package test target"
[[ "${TARGET_KIND}" == "linux" ]] || die "test_package.sh only supports Linux targets"

if [[ -n "$PACKAGE_DIR" && -n "$ARCHIVE" ]]; then
  die "--package-dir and --archive are mutually exclusive"
fi

if [[ -n "$ARCHIVE" ]]; then
  [[ -f "$ARCHIVE" ]] || die "archive not found: ${ARCHIVE}"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgresql18-dist-archive.${PACKAGE_TRIPLE}.XXXXXX")"
  tar -xf "$ARCHIVE" -C "$TEST_ROOT"
  PACKAGE_DIR="$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | sed -n '1p')"
fi

[[ -n "$PACKAGE_DIR" ]] || die "--package-dir or --archive is required"
[[ -d "$PACKAGE_DIR" ]] || die "package directory not found: ${PACKAGE_DIR}"
PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "missing file: ${path}"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "missing directory: ${path}"
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || die "missing executable: ${path}"
}

first_sorted_match() {
  local search_root="$1"
  shift
  local -a matches=()

  mapfile -t matches < <(find "$search_root" "$@" 2>/dev/null | sort) || true
  if [[ "${#matches[@]}" -gt 0 ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

find_package_executable() {
  local exact_name="$1"
  shift

  if [[ -x "${PACKAGE_DIR}/bin/${exact_name}" ]]; then
    printf '%s\n' "${PACKAGE_DIR}/bin/${exact_name}"
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    local pattern="$1"
    local candidate=""
    shift
    candidate="$(first_sorted_match "${PACKAGE_DIR}/bin" -maxdepth 1 -type f -name "${pattern}")"
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

find_first_dir() {
  local base="$1"
  local pattern="$2"

  first_sorted_match "$base" -type d -path "$pattern" -print
}

extension_enabled() {
  local ext_name="$1"
  [[ -f "${PACKAGE_DIR}/share/extension/${ext_name}.control" ]]
}

setup_runtime_env() {
  local python_lib=""
  local python_dynload=""
  local python_site=""
  local perl_config=""
  local perl_archlib=""
  local perl_privlib=""
  local tcl_dir=""
  local proj_dir=""
  local gdal_dir=""

  export PATH="${PACKAGE_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${PACKAGE_DIR}/lib:${PACKAGE_DIR}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

  python_lib="$(find_first_dir "${PACKAGE_DIR}/lib" "*/python3.*")"
  if [[ -n "${python_lib}" ]]; then
    python_dynload="${python_lib}/lib-dynload"
    python_site="${python_lib}/site-packages"
    export PYTHONHOME="${PACKAGE_DIR}"
    export PYTHONPATH="${python_lib}"
    [[ -d "${python_dynload}" ]] && export PYTHONPATH="${PYTHONPATH}:${python_dynload}"
    [[ -d "${python_site}" ]] && export PYTHONPATH="${PYTHONPATH}:${python_site}"
  fi

  perl_config="$(first_sorted_match "${PACKAGE_DIR}/lib" -path '*/Config_heavy.pl' -type f -print)"
  if [[ -n "${perl_config}" ]]; then
    perl_archlib="$(dirname "${perl_config}")"
    perl_privlib="$(dirname "${perl_archlib}")"
    export PERL5LIB="${perl_archlib}:${perl_privlib}${PERL5LIB:+:${PERL5LIB}}"
  fi

  tcl_dir="$(find_first_dir "${PACKAGE_DIR}/lib" "*/tcl8.*")"
  [[ -n "${tcl_dir}" ]] && export TCL_LIBRARY="${tcl_dir}"

  proj_dir="${PACKAGE_DIR}/share/proj"
  gdal_dir="${PACKAGE_DIR}/share/gdal"
  [[ -d "${proj_dir}" ]] && export PROJ_DATA="${proj_dir}"
  [[ -d "${gdal_dir}" ]] && export GDAL_DATA="${gdal_dir}"
}

show_postgresql_log() {
  local log_file="$1"
  if [[ -f "${log_file}" ]]; then
    echo "--- postgresql log: ${log_file} ---" >&2
    tail -n 200 "${log_file}" >&2 || true
    echo "--- end postgresql log ---" >&2
  fi
}

psql_scalar() {
  local psql_bin="$1"
  local host="$2"
  local port="$3"
  local database="$4"
  local sql="$5"

  "${psql_bin}" -h "$host" -p "$port" -U postgres -d "$database" -Atqc "$sql"
}

require_scalar() {
  local psql_bin="$1"
  local host="$2"
  local port="$3"
  local database="$4"
  local sql="$5"
  local expected="$6"
  local actual=""

  actual="$(psql_scalar "$psql_bin" "$host" "$port" "$database" "$sql")"
  [[ "${actual}" == "${expected}" ]] || die "unexpected result for [${sql}]: expected [${expected}], got [${actual}]"
}

require_true() {
  local psql_bin="$1"
  local host="$2"
  local port="$3"
  local database="$4"
  local sql="$5"
  local actual=""

  actual="$(psql_scalar "$psql_bin" "$host" "$port" "$database" "$sql")"
  [[ "${actual}" == "t" || "${actual}" == "1" ]] || die "expected true result for [${sql}], got [${actual}]"
}

run_postgresql18_dist_test() {
  local initdb_bin="$1"
  local pg_ctl_bin="$2"
  local psql_bin="$3"
  local data_dir="$4"
  local socket_dir="$5"
  local log_file="$6"
  local port="$7"
  local host_addr="$8"
  local startup_host="$9"
  local preload_libraries=()
  local preload_setting=""
  local psql_host=""
  local -a failures=()
  local cluster_started=0

  rm -rf "$data_dir" "$socket_dir"
  mkdir -p "$data_dir" "$socket_dir"

  record_failure() {
    local message="$1"
    failures+=("${message}")
    echo "TEST FAILURE: ${message}" >&2
  }

  stop_cluster() {
    if [[ "${cluster_started}" == "1" ]]; then
      "${pg_ctl_bin}" -D "$data_dir" -m immediate stop >/dev/null 2>&1 || true
      cluster_started=0
    fi
  }

  start_cluster() {
    "${pg_ctl_bin}" \
      -D "$data_dir" \
      -l "$log_file" \
      -o "$(printf "%q " "${postgres_opts[@]}")" \
      -w start >/dev/null || {
        show_postgresql_log "${log_file}"
        return 1
      }
    cluster_started=1
    return 0
  }

  ensure_cluster_running() {
    if [[ "${cluster_started}" == "1" ]] && "${pg_ctl_bin}" -D "$data_dir" status >/dev/null 2>&1; then
      return 0
    fi

    echo "postgresql is not running, attempting restart" >&2
    stop_cluster
    if ! start_cluster; then
      record_failure "postgresql cluster restart failed"
      return 0
    fi
    return 0
  }

  run_sql_step() {
    local database="$1"
    local label="$2"
    local sql="$3"

    ensure_cluster_running
    echo "running sql step: ${label}"
    if ! "${psql_bin}" -h "$psql_host" -p "$port" -U postgres -d "$database" -v ON_ERROR_STOP=1 -c "$sql" >/dev/null; then
      echo "sql step failed: ${label}" >&2
      show_postgresql_log "${log_file}"
      record_failure "sql step failed: ${label}"
      stop_cluster
      ensure_cluster_running
    fi
    return 0
  }

  check_scalar() {
    local database="$1"
    local label="$2"
    local sql="$3"
    local expected="$4"
    local actual=""

    ensure_cluster_running
    if ! actual="$("${psql_bin}" -h "$psql_host" -p "$port" -U postgres -d "$database" -Atqc "$sql" 2>/dev/null)"; then
      show_postgresql_log "${log_file}"
      record_failure "query failed: ${label}"
      stop_cluster
      ensure_cluster_running
      return 0
    fi
    if [[ "${actual}" != "${expected}" ]]; then
      record_failure "unexpected result for ${label}: expected [${expected}], got [${actual}]"
      return 0
    fi
    return 0
  }

  check_true() {
    local database="$1"
    local label="$2"
    local sql="$3"
    local actual=""

    ensure_cluster_running
    if ! actual="$("${psql_bin}" -h "$psql_host" -p "$port" -U postgres -d "$database" -Atqc "$sql" 2>/dev/null)"; then
      show_postgresql_log "${log_file}"
      record_failure "query failed: ${label}"
      stop_cluster
      ensure_cluster_running
      return 0
    fi
    if [[ "${actual}" != "t" && "${actual}" != "1" ]]; then
      record_failure "expected true for ${label}, got [${actual}]"
      return 0
    fi
    return 0
  }

  cleanup_cluster() {
    stop_cluster
  }
  trap cleanup_cluster EXIT

  [[ -f "${PACKAGE_DIR}/lib/pgaudit.so" ]] && preload_libraries+=(pgaudit)
  [[ -f "${PACKAGE_DIR}/lib/pg_stat_monitor.so" ]] && preload_libraries+=(pg_stat_monitor)
  if [[ "${#preload_libraries[@]}" -gt 0 ]]; then
    preload_setting="$(IFS=,; echo "${preload_libraries[*]}")"
  fi

  "${initdb_bin}" \
    --username=postgres \
    --auth-local=trust \
    --auth-host=trust \
    --no-instructions \
    -D "$data_dir" >/dev/null

  postgres_opts=(
    "-F"
    "-p" "${port}"
    "-c" "listen_addresses=${startup_host}"
    "-c" "log_destination=stderr"
    "-c" "logging_collector=off"
    "-c" "compute_query_id=on"
    "-c" "log_min_messages=info"
    "-c" "pgaudit.log=read,write,ddl"
    "-c" "pgaudit.log_catalog=on"
  )
  if [[ -n "${preload_setting}" ]]; then
    postgres_opts+=("-c" "shared_preload_libraries=${preload_setting}")
  fi
  if [[ -n "${socket_dir}" ]]; then
    postgres_opts+=("-k" "${socket_dir}")
  fi

  start_cluster || die "postgresql cluster failed to start"

  if [[ -n "${socket_dir}" ]]; then
    psql_host="${socket_dir}"
  else
    psql_host="${host_addr}"
  fi

  run_sql_step postgres "create database" "CREATE DATABASE dist_test;"
  run_sql_step dist_test "create random data table" \
    "CREATE TABLE dist_random_data AS SELECT gs AS id, ((random() * 100)::integer) AS n, format('row-%s postgresql graph search', gs) AS content FROM generate_series(1, 64) AS gs;"

  if extension_enabled plpython3u; then
    run_sql_step dist_test "create extension plpython3u" "CREATE EXTENSION plpython3u;"
    run_sql_step dist_test "create plpython helper codex_plpython_bucket" \
      "CREATE OR REPLACE FUNCTION codex_plpython_bucket(v integer) RETURNS integer LANGUAGE plpython3u AS \$\$ return v * v \$\$;"
    run_sql_step dist_test "create plpython helper codex_plpython_upper" \
      "CREATE OR REPLACE FUNCTION codex_plpython_upper(v text) RETURNS text LANGUAGE plpython3u AS \$\$ return v.upper() \$\$;"
  fi

  if extension_enabled plperl; then
    run_sql_step dist_test "create extension plperl" "CREATE EXTENSION plperl;"
    run_sql_step dist_test "create plperl helper codex_plperl_reverse" \
      "CREATE OR REPLACE FUNCTION codex_plperl_reverse(v text) RETURNS text LANGUAGE plperl AS \$\$ return scalar reverse \$_[0]; \$\$;"
  fi

  if extension_enabled pltcl; then
    run_sql_step dist_test "create extension pltcl" "CREATE EXTENSION pltcl;"
    run_sql_step dist_test "create pltcl helper codex_pltcl_repeat" \
      "CREATE OR REPLACE FUNCTION codex_pltcl_repeat(v text, n integer) RETURNS text LANGUAGE pltcl AS \$\$ return [string repeat \$1 \$2] \$\$;"
  fi

  if extension_enabled plv8; then
    run_sql_step dist_test "create extension plv8" "CREATE EXTENSION plv8;"
    run_sql_step dist_test "create plv8 helper codex_plv8_sum" \
      "CREATE OR REPLACE FUNCTION codex_plv8_sum(v text) RETURNS integer LANGUAGE plv8 AS \$\$ return JSON.parse(v).reduce((a, b) => a + b, 0); \$\$;"
  fi

  if extension_enabled postgis; then
    run_sql_step dist_test "create extension postgis" "CREATE EXTENSION postgis;"
    run_sql_step dist_test "create dist_points" \
      "CREATE TABLE dist_points AS SELECT id, ST_SetSRID(ST_MakePoint(id::double precision, id::double precision), 4326) AS geom FROM generate_series(1, 8) AS id;"
  fi

  if extension_enabled pgrouting; then
    run_sql_step dist_test "create extension pgrouting" "CREATE EXTENSION pgrouting;"
    run_sql_step dist_test "create dist_edges" \
      "CREATE TABLE dist_edges (id bigint, source bigint, target bigint, cost double precision, reverse_cost double precision);"
    run_sql_step dist_test "insert dist_edges" \
      "INSERT INTO dist_edges VALUES (1, 1, 2, 1, 1), (2, 2, 3, 1, 1), (3, 1, 3, 5, 5);"
  fi

  if extension_enabled vector; then
    run_sql_step dist_test "create extension vector" "CREATE EXTENSION vector;"
    run_sql_step dist_test "create dist_vectors" \
      "CREATE TABLE dist_vectors (id integer PRIMARY KEY, embedding vector(3));"
    run_sql_step dist_test "insert dist_vectors" \
      "INSERT INTO dist_vectors VALUES (1, '[0,0,0]'), (2, '[1,1,1]'), (3, '[3,3,3]');"
  fi

  if extension_enabled age; then
    run_sql_step dist_test "create extension age" "CREATE EXTENSION age;"
    run_sql_step dist_test "create age graph" \
      "LOAD 'age'; SET search_path = ag_catalog, \"\$user\", public; SELECT create_graph('dist_graph'); RESET search_path;"
  fi

  if extension_enabled pgroonga; then
    run_sql_step dist_test "create extension pgroonga" "CREATE EXTENSION pgroonga;"
    run_sql_step dist_test "create dist_docs" \
      "CREATE TABLE dist_docs (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, content text NOT NULL);"
    run_sql_step dist_test "insert dist_docs" \
      "INSERT INTO dist_docs(content) VALUES ('postgresql extension testing with pgroonga'), ('graph search with postgresql and groonga'), ('plain text row');"
    run_sql_step dist_test "create pgroonga index" \
      "CREATE INDEX dist_docs_content_idx ON dist_docs USING pgroonga (content);"
  fi

  if extension_enabled pgaudit; then
    run_sql_step dist_test "create extension pgaudit" "CREATE EXTENSION pgaudit;"
    run_sql_step dist_test "run pgaudit probe" \
      "SELECT /* codex_audit_probe */ count(*) FROM dist_random_data;"
  fi

  if extension_enabled pg_stat_monitor; then
    run_sql_step dist_test "create extension pg_stat_monitor" "CREATE EXTENSION pg_stat_monitor;"
    run_sql_step dist_test "reset pg_stat_monitor" \
      "SELECT pg_stat_monitor_reset();"
    run_sql_step dist_test "run pg_stat_monitor probe" \
      "SELECT /* codex_monitor_probe */ count(*) FROM dist_random_data WHERE n >= 0;"
  fi

  check_scalar dist_test "count random data" "SELECT count(*) FROM dist_random_data;" "64"
  check_true dist_test "avg random data nonnegative" "SELECT avg(n) >= 0 FROM dist_random_data;"

  if extension_enabled plpython3u; then
    check_scalar dist_test "plpython bucket" "SELECT codex_plpython_bucket(7);" "49"
    check_scalar dist_test "plpython upper" "SELECT codex_plpython_upper(content) FROM dist_random_data ORDER BY id LIMIT 1;" "ROW-1 POSTGRESQL GRAPH SEARCH"
  fi
  if extension_enabled plperl; then
    check_scalar dist_test "plperl reverse" "SELECT codex_plperl_reverse('stressed');" "desserts"
  fi
  if extension_enabled pltcl; then
    check_scalar dist_test "pltcl repeat" "SELECT codex_pltcl_repeat('pg', 3);" "pgpgpg"
  fi
  if extension_enabled plv8; then
    check_scalar dist_test "plv8 sum" "SELECT codex_plv8_sum('[1,2,3,4]');" "10"
  fi
  if extension_enabled postgis; then
    check_true dist_test "postgis full version has proj" "SELECT postgis_full_version() LIKE '%PROJ%';"
    check_true dist_test "postgis transform srid" "SELECT ST_SRID(ST_Transform(ST_SetSRID(ST_MakePoint(116.397,39.908),4326),3857)) = 3857;"
  fi
  if extension_enabled pgrouting; then
    check_scalar dist_test "pgrouting dijkstra" "SELECT array_to_string(array_agg(node ORDER BY seq), ',') FROM pgr_dijkstra('SELECT id, source, target, cost, reverse_cost FROM dist_edges', 1, 3, true);" "1,2,3"
  fi
  if extension_enabled vector; then
    check_scalar dist_test "vector nearest neighbor" "SELECT id FROM dist_vectors ORDER BY embedding <-> '[1,1,1]'::vector LIMIT 1;" "2"
  fi
  if extension_enabled age; then
    check_scalar dist_test "age graph count" "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = 'dist_graph';" "1"
    check_scalar dist_test "age cypher return 1" "LOAD 'age'; SELECT * FROM ag_catalog.cypher('dist_graph', \$\$ RETURN 1 \$\$) AS (v ag_catalog.agtype);" "1"
    check_scalar dist_test "age cypher return 6" "LOAD 'age'; SELECT * FROM ag_catalog.cypher('dist_graph', \$\$ RETURN 6 \$\$) AS (v ag_catalog.agtype);" "6"
  fi
  if extension_enabled pgroonga; then
    check_true dist_test "pgroonga match count" "SELECT count(*) >= 2 FROM dist_docs WHERE content &@~ 'postgresql';"
  fi
  if extension_enabled pg_stat_monitor; then
    check_true dist_test "pg_stat_monitor probe recorded" "SELECT EXISTS (SELECT 1 FROM pg_stat_monitor WHERE query LIKE '%codex_monitor_probe%' AND calls > 0);"
  fi

  if extension_enabled pgaudit; then
    sleep 1
    grep -Fq "AUDIT:" "$log_file" || record_failure "pgaudit log entry not found in ${log_file}"
    grep -Fq "codex_audit_probe" "$log_file" || record_failure "pgaudit probe query not found in ${log_file}"
  fi

  stop_cluster
  trap - EXIT

  if [[ "${#failures[@]}" -gt 0 ]]; then
    echo "PostgreSQL 18 dist package test completed with failures:" >&2
    printf ' - %s\n' "${failures[@]}" >&2
    return 1
  fi
}

require_dir "${PACKAGE_DIR}/bin"
require_dir "${PACKAGE_DIR}/lib"
require_dir "${PACKAGE_DIR}/share/extension"
require_file "${PACKAGE_DIR}/bin/postgres"
require_file "${PACKAGE_DIR}/bin/psql"
require_file "${PACKAGE_DIR}/bin/initdb"
require_file "${PACKAGE_DIR}/bin/pg_ctl"
require_file "${PACKAGE_DIR}/share/extension/plpgsql.control"

setup_runtime_env

INITDB_BIN="$(find_package_executable initdb)"
PG_CTL_BIN="$(find_package_executable pg_ctl)"
PSQL_BIN="$(find_package_executable psql)"
POSTGRES_BIN="$(find_package_executable postgres)"
PYTHON_BIN="$(find_package_executable python3 'python3.[0-9]*' 'python[0-9].[0-9]*' 'python' || true)"
PERL_BIN="$(find_package_executable perl 'perl[0-9]*' || true)"
TCLSH_BIN="$(find_package_executable tclsh8.6 'tclsh8.6.bin' 'tclsh*.bin' 'tclsh*' || true)"

require_executable "${INITDB_BIN}"
require_executable "${PG_CTL_BIN}"
require_executable "${PSQL_BIN}"
require_executable "${POSTGRES_BIN}"
[[ -n "${PYTHON_BIN}" ]] && require_executable "${PYTHON_BIN}"
[[ -n "${PERL_BIN}" ]] && require_executable "${PERL_BIN}"
[[ -n "${TCLSH_BIN}" ]] && require_executable "${TCLSH_BIN}"

if extension_enabled plpython3u; then
  require_file "${PACKAGE_DIR}/share/extension/plpython3u.control"
  [[ -n "${PYTHON_BIN}" ]] || die "plpython3u is present but no package python executable was found"
  "${PYTHON_BIN}" -c 'import sys; print(sys.version)'
fi
if extension_enabled plperl; then
  require_file "${PACKAGE_DIR}/share/extension/plperl.control"
  [[ -n "${PERL_BIN}" ]] || die "plperl is present but no package perl executable was found"
  "${PERL_BIN}" -e 'print "perl runtime ok\n";'
fi
if extension_enabled pltcl; then
  require_file "${PACKAGE_DIR}/share/extension/pltcl.control"
  [[ -n "${TCLSH_BIN}" ]] || die "pltcl is present but no package tclsh executable was found"
  "${TCLSH_BIN}" <<'TCL'
puts "tcl runtime ok"
TCL
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgresql18-dist-test.XXXXXX")"
DATA_DIR="${TEST_ROOT}/data"
SOCKET_DIR="${TEST_ROOT}/socket"
LOG_FILE="${TEST_ROOT}/postgresql.log"
PORT=$((55432 + (RANDOM % 1000)))
HOST_ADDR="127.0.0.1"

run_postgresql18_dist_test \
  "${INITDB_BIN}" \
  "${PG_CTL_BIN}" \
  "${PSQL_BIN}" \
  "${DATA_DIR}" \
  "${SOCKET_DIR}" \
  "${LOG_FILE}" \
  "${PORT}" \
  "${HOST_ADDR}" \
  ""

echo "PostgreSQL 18 dist package test passed: ${PACKAGE_TRIPLE}"
