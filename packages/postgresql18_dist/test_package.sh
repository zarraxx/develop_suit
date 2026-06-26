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
  TEST_ROOT="${ROOT_DIR}/build/test/${PACKAGE_TRIPLE}"
  rm -rf "$TEST_ROOT"
  mkdir -p "$TEST_ROOT"
  tar -xf "$ARCHIVE" -C "$TEST_ROOT"
  PACKAGE_DIR="$(
    find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -print \
      | sort \
      | head -n 1
  )"
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
    candidate="$(find "${PACKAGE_DIR}/bin" -maxdepth 1 -type f -name "${pattern}" | sort | head -n 1 || true)"
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

  find "$base" -type d -path "$pattern" -print 2>/dev/null \
    | sort \
    | head -n 1
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

  perl_config="$(
    find "${PACKAGE_DIR}/lib" -path '*/Config_heavy.pl' -type f -print 2>/dev/null \
      | sort \
      | head -n 1
  )"
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

append_sql() {
  local sql_file="$1"
  shift
  printf '%s\n' "$@" >> "${sql_file}"
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
  local sql_file="${10}"
  local preload_libraries=()
  local preload_setting=""
  local psql_host=""

  rm -rf "$data_dir" "$socket_dir"
  mkdir -p "$data_dir" "$socket_dir"

  cleanup_cluster() {
    if [[ -n "${pg_ctl_bin:-}" && -d "$data_dir" ]]; then
      "${pg_ctl_bin}" -D "$data_dir" -m immediate stop >/dev/null 2>&1 || true
    fi
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

  "${pg_ctl_bin}" \
    -D "$data_dir" \
    -l "$log_file" \
    -o "$(printf "%q " "${postgres_opts[@]}")" \
    -w start >/dev/null

  if [[ -n "${socket_dir}" ]]; then
    psql_host="${socket_dir}"
  else
    psql_host="${host_addr}"
  fi

  "${psql_bin}" \
    -h "$psql_host" \
    -p "$port" \
    -U postgres \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -f "${sql_file}" >/dev/null

  require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT count(*) FROM dist_random_data;" "64"
  require_true "$psql_bin" "$psql_host" "$port" dist_test "SELECT avg(n) >= 0 FROM dist_random_data;"

  if extension_enabled plpython3u; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT codex_plpython_bucket(7);" "49"
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT codex_plpython_upper(content) FROM dist_random_data ORDER BY id LIMIT 1;" "ROW-1 POSTGRESQL GRAPH SEARCH"
  fi
  if extension_enabled plperl; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT codex_plperl_reverse('stressed');" "desserts"
  fi
  if extension_enabled pltcl; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT codex_pltcl_repeat('pg', 3);" "pgpgpg"
  fi
  if extension_enabled plv8; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT codex_plv8_sum('[1,2,3,4]');" "10"
  fi
  if extension_enabled postgis; then
    require_true "$psql_bin" "$psql_host" "$port" dist_test "SELECT postgis_full_version() LIKE '%PROJ%';"
    require_true "$psql_bin" "$psql_host" "$port" dist_test "SELECT ST_SRID(ST_Transform(ST_SetSRID(ST_MakePoint(116.397,39.908),4326),3857)) = 3857;"
  fi
  if extension_enabled pgrouting; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT array_to_string(array_agg(node ORDER BY seq), ',') FROM pgr_dijkstra('SELECT id, source, target, cost, reverse_cost FROM dist_edges', 1, 3, true);" "1,2,3"
  fi
  if extension_enabled vector; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT id FROM dist_vectors ORDER BY embedding <-> '[1,1,1]'::vector LIMIT 1;" "2"
  fi
  if extension_enabled age; then
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = 'dist_graph';" "1"
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "LOAD 'age'; SELECT * FROM ag_catalog.cypher('dist_graph', \$\$ RETURN 1 \$\$) AS (v ag_catalog.agtype);" "1"
    require_scalar "$psql_bin" "$psql_host" "$port" dist_test "LOAD 'age'; SELECT * FROM ag_catalog.cypher('dist_graph', \$\$ RETURN 6 \$\$) AS (v ag_catalog.agtype);" "6"
  fi
  if extension_enabled pgroonga; then
    require_true "$psql_bin" "$psql_host" "$port" dist_test "SELECT count(*) >= 2 FROM dist_docs WHERE content &@~ 'postgresql';"
  fi
  if extension_enabled pg_stat_monitor; then
    require_true "$psql_bin" "$psql_host" "$port" dist_test "SELECT EXISTS (SELECT 1 FROM pg_stat_monitor WHERE query LIKE '%codex_monitor_probe%' AND calls > 0);"
  fi

  if extension_enabled pgaudit; then
    sleep 1
    grep -Fq "AUDIT:" "$log_file" || die "pgaudit log entry not found in ${log_file}"
    grep -Fq "codex_audit_probe" "$log_file" || die "pgaudit probe query not found in ${log_file}"
  fi

  "${pg_ctl_bin}" -D "$data_dir" -m fast stop >/dev/null
  trap - EXIT
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
SQL_FILE="${TEST_ROOT}/test.sql"
PORT=$((55432 + (RANDOM % 1000)))
HOST_ADDR="127.0.0.1"

cat > "${SQL_FILE}" <<'SQL'
CREATE DATABASE dist_test;
\connect dist_test

CREATE TABLE dist_random_data AS
SELECT
  gs AS id,
  ((random() * 100)::integer) AS n,
  format('row-%s postgresql graph search', gs) AS content
FROM generate_series(1, 64) AS gs;
SQL

if extension_enabled plpython3u; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION plpython3u;" \
    "CREATE OR REPLACE FUNCTION codex_plpython_bucket(v integer) RETURNS integer LANGUAGE plpython3u AS \$\$ return v * v \$\$;" \
    "CREATE OR REPLACE FUNCTION codex_plpython_upper(v text) RETURNS text LANGUAGE plpython3u AS \$\$ return v.upper() \$\$;"
fi

if extension_enabled plperl; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION plperl;" \
    "CREATE OR REPLACE FUNCTION codex_plperl_reverse(v text) RETURNS text LANGUAGE plperl AS \$\$ return scalar reverse \$_[0]; \$\$;"
fi

if extension_enabled pltcl; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION pltcl;" \
    "CREATE OR REPLACE FUNCTION codex_pltcl_repeat(v text, n integer) RETURNS text LANGUAGE pltcl AS \$\$ return [string repeat \$1 \$2] \$\$;"
fi

if extension_enabled plv8; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION plv8;" \
    "CREATE OR REPLACE FUNCTION codex_plv8_sum(v text) RETURNS integer LANGUAGE plv8 AS \$\$ return JSON.parse(v).reduce((a, b) => a + b, 0); \$\$;"
fi

if extension_enabled postgis; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION postgis;" \
    "CREATE TABLE dist_points AS SELECT id, ST_SetSRID(ST_MakePoint(id::double precision, id::double precision), 4326) AS geom FROM generate_series(1, 8) AS id;"
fi

if extension_enabled pgrouting; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION pgrouting;" \
    "CREATE TABLE dist_edges (id bigint, source bigint, target bigint, cost double precision, reverse_cost double precision);" \
    "INSERT INTO dist_edges VALUES (1, 1, 2, 1, 1), (2, 2, 3, 1, 1), (3, 1, 3, 5, 5);"
fi

if extension_enabled vector; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION vector;" \
    "CREATE TABLE dist_vectors (id integer PRIMARY KEY, embedding vector(3));" \
    "INSERT INTO dist_vectors VALUES (1, '[0,0,0]'), (2, '[1,1,1]'), (3, '[3,3,3]');"
fi

if extension_enabled age; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION age;" \
    "LOAD 'age';" \
    "SET search_path = ag_catalog, \"\$user\", public;" \
    "SELECT create_graph('dist_graph');" \
    "RESET search_path;"
fi

if extension_enabled pgroonga; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION pgroonga;" \
    "CREATE TABLE dist_docs (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, content text NOT NULL);" \
    "INSERT INTO dist_docs(content) VALUES ('postgresql extension testing with pgroonga'), ('graph search with postgresql and groonga'), ('plain text row');" \
    "CREATE INDEX dist_docs_content_idx ON dist_docs USING pgroonga (content);"
fi

if extension_enabled pgaudit; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION pgaudit;" \
    "SELECT /* codex_audit_probe */ count(*) FROM dist_random_data;"
fi

if extension_enabled pg_stat_monitor; then
  append_sql "${SQL_FILE}" \
    "CREATE EXTENSION pg_stat_monitor;" \
    "SELECT pg_stat_monitor_reset();" \
    "SELECT /* codex_monitor_probe */ count(*) FROM dist_random_data WHERE n >= 0;"
fi

run_postgresql18_dist_test \
  "${INITDB_BIN}" \
  "${PG_CTL_BIN}" \
  "${PSQL_BIN}" \
  "${DATA_DIR}" \
  "${SOCKET_DIR}" \
  "${LOG_FILE}" \
  "${PORT}" \
  "${HOST_ADDR}" \
  "" \
  "${SQL_FILE}"

echo "PostgreSQL 18 dist package test passed: ${PACKAGE_TRIPLE}"
