#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./packages/postgresql18_dist/test_package_mingw64.sh --target=mingw64 --archive=<tar.xz>
  ./packages/postgresql18_dist/test_package_mingw64.sh --target=mingw64 --package-dir=<dir>
EOF
}

TARGET=""
PACKAGE_DIR=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      shift
      [[ $# -gt 0 ]] || { echo "--target requires a value" >&2; exit 1; }
      TARGET="$1"
      ;;
    --package-dir=*) PACKAGE_DIR="${1#*=}" ;;
    --package-dir)
      shift
      [[ $# -gt 0 ]] || { echo "--package-dir requires a value" >&2; exit 1; }
      PACKAGE_DIR="$1"
      ;;
    --archive=*) ARCHIVE="${1#*=}" ;;
    --archive)
      shift
      [[ $# -gt 0 ]] || { echo "--archive requires a value" >&2; exit 1; }
      ARCHIVE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

case "${TARGET}" in
  mingw64|windows|x86_64-w64-windows-gnu) ;;
  *)
    echo "test_package_mingw64.sh only supports mingw64/windows targets" >&2
    exit 1
    ;;
esac

if [[ -n "${PACKAGE_DIR}" && -n "${ARCHIVE}" ]]; then
  echo "--package-dir and --archive are mutually exclusive" >&2
  exit 1
fi

show_log() {
  local log_file="$1"
  if [[ -f "${log_file}" ]]; then
    echo "--- postgresql log: ${log_file} ---" >&2
    tail -n 200 "${log_file}" >&2 || true
    echo "--- end postgresql log ---" >&2
  fi
}

log_section() {
  local title="$1"
  echo "=== ${title} ===" >&2
}

show_file_head() {
  local path="$1"
  local lines="${2:-80}"
  if [[ -f "${path}" ]]; then
    echo "--- file: ${path} (first ${lines} lines) ---" >&2
    sed -n "1,${lines}p" "${path}" >&2 || true
    echo "--- end file: ${path} ---" >&2
  fi
}

show_runtime_context() {
  log_section "runtime context"
  echo "package_dir=${PACKAGE_DIR}" >&2
  echo "port=${PORT}" >&2
  echo "data_dir=${DATA_DIR}" >&2
  echo "log_file=${LOG_FILE}" >&2
  echo "shared_preload=${SHARED_PRELOAD[*]:-(none)}" >&2
  echo "postgres_opts=${POSTGRES_OPTS[*]}" >&2
  echo "proj_data=${PROJ_DATA:-}" >&2
  echo "gdal_data=${GDAL_DATA:-}" >&2
  echo "pythonhome=${PYTHONHOME:-}" >&2
  echo "pythonpath=${PYTHONPATH:-}" >&2
  echo "perl5lib=${PERL5LIB:-}" >&2
  echo "tcl_library=${TCL_LIBRARY:-}" >&2
  echo "extensions=$(find "${PACKAGE_DIR}/share/extension" -maxdepth 1 -name '*.control' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" >&2
}

show_cluster_context() {
  log_section "cluster context"
  "${PACKAGE_DIR}/bin/pg_ctl.exe" -D "${DATA_DIR}" status >&2 || true
  echo "--- data directory files ---" >&2
  find "${DATA_DIR}" -maxdepth 2 \( -type f -o -type d \) | LC_ALL=C sort >&2 || true
  echo "--- end data directory files ---" >&2
  show_file_head "${DATA_DIR}/postgresql.conf" 120
  show_file_head "${DATA_DIR}/postgresql.auto.conf" 120
  show_file_head "${DATA_DIR}/postmaster.opts" 40
  show_file_head "${DATA_DIR}/postmaster.pid" 20
}

show_command_output() {
  local label="$1"
  local file_path="$2"
  if [[ -s "${file_path}" ]]; then
    echo "--- ${label}: ${file_path} ---" >&2
    cat "${file_path}" >&2 || true
    echo "--- end ${label} ---" >&2
  fi
}

psql_scalar() {
  local psql_bin="$1"
  local host="$2"
  local port="$3"
  local database="$4"
  local sql="$5"

  "${psql_bin}" -h "${host}" -p "${port}" -U postgres -d "${database}" -Atqc "${sql}"
}

extension_enabled() {
  local ext_name="$1"
  [[ -f "${PACKAGE_DIR}/share/extension/${ext_name}.control" ]]
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${ARCHIVE}" ]]; then
  [[ -f "${ARCHIVE}" ]] || { echo "archive not found: ${ARCHIVE}" >&2; exit 1; }
  TEST_ROOT="${ROOT_DIR}/build/test/x86_64-w64-windows-gnu"
  rm -rf "${TEST_ROOT}"
  mkdir -p "${TEST_ROOT}"
  tar -xf "${ARCHIVE}" \
    --exclude='*/share/terminfo' \
    --exclude='*/share/terminfo/*' \
    -C "${TEST_ROOT}"
  PACKAGE_DIR="$(find "${TEST_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | sed -n '1p')"
fi

[[ -n "${PACKAGE_DIR}" ]] || { echo "--package-dir or --archive is required" >&2; exit 1; }
[[ -d "${PACKAGE_DIR}" ]] || { echo "package directory not found: ${PACKAGE_DIR}" >&2; exit 1; }
PACKAGE_DIR="$(cd "${PACKAGE_DIR}" && pwd)"

for path in \
  "${PACKAGE_DIR}/bin/postgres.exe" \
  "${PACKAGE_DIR}/bin/psql.exe" \
  "${PACKAGE_DIR}/bin/initdb.exe" \
  "${PACKAGE_DIR}/bin/pg_ctl.exe" \
  "${PACKAGE_DIR}/share/extension/plpgsql.control"; do
  [[ -e "${path}" ]] || { echo "missing path: ${path}" >&2; exit 1; }
done

export PATH="${PACKAGE_DIR}/bin:${PACKAGE_DIR}/lib:${PATH}"
[[ -d "${PACKAGE_DIR}/share/proj" ]] && export PROJ_DATA="${PACKAGE_DIR}/share/proj"
[[ -d "${PACKAGE_DIR}/share/gdal" ]] && export GDAL_DATA="${PACKAGE_DIR}/share/gdal"

PYTHON_DIR="$(find "${PACKAGE_DIR}/lib" -type d -path '*/python3.*' | sort | sed -n '1p')"
if [[ -n "${PYTHON_DIR:-}" ]]; then
  export PYTHONHOME="${PACKAGE_DIR}"
  export PYTHONPATH="${PYTHON_DIR}"
  [[ -d "${PYTHON_DIR}/lib-dynload" ]] && export PYTHONPATH="${PYTHONPATH}:${PYTHON_DIR}/lib-dynload"
  [[ -d "${PYTHON_DIR}/site-packages" ]] && export PYTHONPATH="${PYTHONPATH}:${PYTHON_DIR}/site-packages"
fi

PERL_CONFIG="$(find "${PACKAGE_DIR}/lib" -type f -path '*/Config_heavy.pl' | sort | sed -n '1p')"
if [[ -n "${PERL_CONFIG:-}" ]]; then
  PERL_ARCHLIB="$(dirname "${PERL_CONFIG}")"
  PERL_PRIVLIB="$(dirname "${PERL_ARCHLIB}")"
  export PERL5LIB="${PERL_ARCHLIB}:${PERL_PRIVLIB}${PERL5LIB:+:${PERL5LIB}}"
fi

TCL_DIR="$(find "${PACKAGE_DIR}/lib" -type d -path '*/tcl8.*' | sort | sed -n '1p')"
[[ -n "${TCL_DIR:-}" ]] && export TCL_LIBRARY="${TCL_DIR}"

[[ ! -f "${PACKAGE_DIR}/share/extension/plpython3u.control" ]] || "${PACKAGE_DIR}/bin/python3.exe" -c 'import sys; print(sys.version)'
[[ ! -f "${PACKAGE_DIR}/share/extension/plperl.control" ]] || "${PACKAGE_DIR}/bin/perl.exe" -e 'print "perl runtime ok\n";'
if [[ -f "${PACKAGE_DIR}/share/extension/pltcl.control" ]]; then
  "${PACKAGE_DIR}/bin/tclsh86.exe" <<'TCL'
puts "tcl runtime ok"
TCL
fi

TEST_ROOT="$(mktemp -d)"
DATA_DIR="${TEST_ROOT}/data"
LOG_FILE="${TEST_ROOT}/postgresql.log"
STEP_STDOUT="${TEST_ROOT}/step.stdout"
STEP_STDERR="${TEST_ROOT}/step.stderr"
PORT=56432

mkdir -p "${DATA_DIR}"

SHARED_PRELOAD=()
[[ -f "${PACKAGE_DIR}/lib/pgaudit.dll" ]] && SHARED_PRELOAD+=(pgaudit)
[[ -f "${PACKAGE_DIR}/lib/pg_stat_monitor.dll" ]] && SHARED_PRELOAD+=(pg_stat_monitor)
FAILURES=()
CLUSTER_STARTED=0

"${PACKAGE_DIR}/bin/initdb.exe" --username=postgres --auth-local=trust --auth-host=trust --no-instructions -D "${DATA_DIR}" >/dev/null

POSTGRES_OPTS=(
  "-F"
  "-p" "${PORT}"
  "-c" "listen_addresses=127.0.0.1"
  "-c" "log_destination=stderr"
  "-c" "logging_collector=off"
  "-c" "compute_query_id=on"
  "-c" "pgaudit.log=read,write,ddl"
  "-c" "pgaudit.log_catalog=on"
)

if [[ "${#SHARED_PRELOAD[@]}" -gt 0 ]]; then
  POSTGRES_OPTS+=("-c" "shared_preload_libraries=$(IFS=,; echo "${SHARED_PRELOAD[*]}")")
fi

record_failure() {
  local message="$1"
  FAILURES+=("${message}")
  echo "TEST FAILURE: ${message}" >&2
}

stop_cluster() {
  if [[ "${CLUSTER_STARTED}" == "1" ]]; then
    "${PACKAGE_DIR}/bin/pg_ctl.exe" -D "${DATA_DIR}" -m immediate stop >/dev/null 2>&1 || true
    CLUSTER_STARTED=0
  fi
}

start_cluster() {
  local postgres_opts_string=""

  postgres_opts_string="$(printf '%s\n' "${POSTGRES_OPTS[*]}")"
  log_section "starting cluster"
  echo "pg_ctl options: ${postgres_opts_string}" >&2
  "${PACKAGE_DIR}/bin/pg_ctl.exe" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "${postgres_opts_string}" -w start >/dev/null || {
    show_log "${LOG_FILE}"
    show_cluster_context
    return 1
  }
  CLUSTER_STARTED=1
  return 0
}

ensure_cluster_running() {
  if [[ "${CLUSTER_STARTED}" == "1" ]] && "${PACKAGE_DIR}/bin/pg_ctl.exe" -D "${DATA_DIR}" status >/dev/null 2>&1; then
    return 0
  fi

  echo "postgresql is not running, attempting restart" >&2
  stop_cluster
  if ! start_cluster; then
    record_failure "postgresql cluster restart failed"
  fi
  return 0
}

run_sql_step() {
  local database="$1"
  local label="$2"
  local sql="$3"

  ensure_cluster_running
  echo "running sql step: ${label}"
  : > "${STEP_STDOUT}"
  : > "${STEP_STDERR}"
  if ! "${PACKAGE_DIR}/bin/psql.exe" -h 127.0.0.1 -p "${PORT}" -U postgres -d "${database}" -v ON_ERROR_STOP=1 -c "${sql}" >"${STEP_STDOUT}" 2>"${STEP_STDERR}"; then
    echo "sql step failed: ${label}" >&2
    echo "database=${database}" >&2
    echo "sql=${sql}" >&2
    show_command_output "psql stdout" "${STEP_STDOUT}"
    show_command_output "psql stderr" "${STEP_STDERR}"
    show_log "${LOG_FILE}"
    show_cluster_context
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
  : > "${STEP_STDOUT}"
  : > "${STEP_STDERR}"
  if ! actual="$("${PACKAGE_DIR}/bin/psql.exe" -h 127.0.0.1 -p "${PORT}" -U postgres -d "${database}" -Atqc "${sql}" 2>"${STEP_STDERR}")"; then
    show_command_output "psql stderr" "${STEP_STDERR}"
    echo "database=${database}" >&2
    echo "sql=${sql}" >&2
    show_log "${LOG_FILE}"
    show_cluster_context
    record_failure "query failed: ${label}"
    stop_cluster
    ensure_cluster_running
    return 0
  fi
  [[ "${actual}" == "${expected}" ]] || record_failure "unexpected result for ${label}: expected [${expected}], got [${actual}]"
  return 0
}

check_true() {
  local database="$1"
  local label="$2"
  local sql="$3"
  local actual=""

  ensure_cluster_running
  : > "${STEP_STDOUT}"
  : > "${STEP_STDERR}"
  if ! actual="$("${PACKAGE_DIR}/bin/psql.exe" -h 127.0.0.1 -p "${PORT}" -U postgres -d "${database}" -Atqc "${sql}" 2>"${STEP_STDERR}")"; then
    show_command_output "psql stderr" "${STEP_STDERR}"
    echo "database=${database}" >&2
    echo "sql=${sql}" >&2
    show_log "${LOG_FILE}"
    show_cluster_context
    record_failure "query failed: ${label}"
    stop_cluster
    ensure_cluster_running
    return 0
  fi
  [[ "${actual}" == "t" ]] || record_failure "expected true for ${label}, got [${actual}]"
  return 0
}

cleanup() {
  stop_cluster
}
trap cleanup EXIT

show_runtime_context
start_cluster || exit 1

run_sql_step postgres "create database" "CREATE DATABASE dist_test;"
run_sql_step dist_test "create random data table" \
  "CREATE TABLE dist_random_data AS SELECT gs AS id, ((random() * 100)::integer) AS n, format('row-%s postgresql windows search', gs) AS content FROM generate_series(1, 64) AS gs;"

if extension_enabled postgis; then
  run_sql_step dist_test "create extension postgis" "CREATE EXTENSION postgis;"
  run_sql_step dist_test "create dist_points" \
    "CREATE TABLE dist_points AS SELECT id, ST_SetSRID(ST_MakePoint(id::double precision, id::double precision), 4326) AS geom FROM generate_series(1, 8) AS id;"
fi

if extension_enabled vector; then
  run_sql_step dist_test "create extension vector" "CREATE EXTENSION vector;"
  run_sql_step dist_test "create dist_vectors" \
    "CREATE TABLE dist_vectors (id integer PRIMARY KEY, embedding vector(3));"
  run_sql_step dist_test "insert dist_vectors" \
    "INSERT INTO dist_vectors VALUES (1, '[0,0,0]'), (2, '[1,1,1]'), (3, '[3,3,3]');"
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
  run_sql_step dist_test "reset pg_stat_monitor" "SELECT pg_stat_monitor_reset();"
  run_sql_step dist_test "run pg_stat_monitor probe" \
    "SELECT /* codex_monitor_probe */ count(*) FROM dist_random_data WHERE n >= 0;"
fi

check_scalar dist_test "count random data" "SELECT count(*) FROM dist_random_data;" "64"

if extension_enabled postgis; then
  check_scalar dist_test "postgis transform srid" "SELECT ST_SRID(ST_Transform(ST_SetSRID(ST_MakePoint(116.397,39.908),4326),3857));" "3857"
fi

if extension_enabled vector; then
  check_scalar dist_test "vector nearest neighbor" "SELECT id FROM dist_vectors ORDER BY embedding <-> '[1,1,1]'::vector LIMIT 1;" "2"
fi

if extension_enabled pgroonga; then
  check_true dist_test "pgroonga match count" "SELECT count(*) >= 2 FROM dist_docs WHERE content &@~ 'postgresql';"
fi

if extension_enabled pg_stat_monitor; then
  check_true dist_test "pg_stat_monitor probe recorded" "SELECT EXISTS (SELECT 1 FROM pg_stat_monitor WHERE query LIKE '%codex_monitor_probe%' AND calls > 0);"
fi

if extension_enabled pgaudit; then
  sleep 1
  grep -Fq "AUDIT:" "${LOG_FILE}" || record_failure "pgaudit log entry not found"
  grep -Fq "codex_audit_probe" "${LOG_FILE}" || record_failure "pgaudit probe query not found"
fi

stop_cluster
trap - EXIT

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo "PostgreSQL 18 dist package test completed with failures:" >&2
  printf ' - %s\n' "${FAILURES[@]}" >&2
  exit 1
fi

echo "PostgreSQL 18 dist package test passed: x86_64-w64-windows-gnu"
