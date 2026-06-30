#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./packages/postgresql/test_package_mingw64.sh --target=mingw64 --archive=<tar.xz>
  ./packages/postgresql/test_package_mingw64.sh --target=mingw64 --package-dir=<dir>
EOF
}

TARGET=""
PACKAGE_DIR=""
ARCHIVE=""
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRESQL_EXPECT_LLVM_JIT="${POSTGRESQL_EXPECT_LLVM_JIT:-0}"

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
   
psql_scalar() {
  local psql_bin="$1"
  local host="$2"
  local port="$3"
  local database="$4"
  local sql="$5"

  "${psql_bin}" -h "${host}" -p "${port}" -U postgres -d "${database}" -Atqc "${sql}"
}

package_has_llvm_jit() {
  [[ -f "${PACKAGE_DIR}/lib/llvmjit.dll" || -f "${PACKAGE_DIR}/lib/llvmjit.so" ]]
}

run_postgresql_jit_test() {
  local jit_setting=""
  local jit_provider=""
  local jit_available=""
  local jit_sum=""

  if ! package_has_llvm_jit; then
    if [[ "$POSTGRESQL_EXPECT_LLVM_JIT" == "1" ]]; then
      show_log "${LOG_FILE}"
      echo "missing PostgreSQL LLVM JIT module" >&2
      exit 1
    fi
    return 0
  fi

  echo "Running PostgreSQL LLVM JIT test"

  jit_setting="$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SHOW jit")" \
    || { show_log "${LOG_FILE}"; exit 1; }
  [[ "$jit_setting" == "on" ]] \
    || { show_log "${LOG_FILE}"; echo "unexpected jit setting: ${jit_setting}" >&2; exit 1; }

  jit_provider="$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SHOW jit_provider")" \
    || { show_log "${LOG_FILE}"; exit 1; }
  [[ "$jit_provider" == "llvmjit" ]] \
    || { show_log "${LOG_FILE}"; echo "unexpected jit_provider: ${jit_provider}" >&2; exit 1; }

  jit_available="$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SELECT pg_jit_available()")" \
    || { show_log "${LOG_FILE}"; exit 1; }
  [[ "$jit_available" == "t" ]] \
    || { show_log "${LOG_FILE}"; echo "pg_jit_available() returned: ${jit_available}" >&2; exit 1; }

  jit_sum="$("${PACKAGE_DIR}/bin/psql.exe" -h 127.0.0.1 -p "${PORT}" -U postgres -d base_test -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET jit = on;
SET jit_above_cost = 0;
SET jit_inline_above_cost = 0;
SET jit_optimize_above_cost = 0;
SELECT sum((i::bigint * i::bigint)) FROM generate_series(1, 10000) AS g(i);
SQL
)" || { show_log "${LOG_FILE}"; exit 1; }
  [[ "$jit_sum" == "333383335000" ]] \
    || { show_log "${LOG_FILE}"; echo "JIT query returned unexpected result: ${jit_sum}" >&2; exit 1; }
}

if [[ -n "${ARCHIVE}" ]]; then
  [[ -f "${ARCHIVE}" ]] || { echo "archive not found: ${ARCHIVE}" >&2; exit 1; }
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgresql-mingw-archive.XXXXXX")"
  tar -xf "${ARCHIVE}" -C "${TEST_ROOT}"
  PACKAGE_DIR="$(find "${TEST_ROOT}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | sed -n '1p')"
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

if [[ -f "${PACKAGE_DIR}/share/extension/plpython3u.control" ]]; then
  "${PACKAGE_DIR}/bin/python3.exe" -c 'print("python runtime ok")'
fi
if [[ -f "${PACKAGE_DIR}/share/extension/plperl.control" ]]; then
  "${PACKAGE_DIR}/bin/perl.exe" -e 'print "perl runtime ok\n";'
fi
if [[ -f "${PACKAGE_DIR}/share/extension/pltcl.control" ]]; then
  "${PACKAGE_DIR}/bin/tclsh86.exe" <<'TCL'
puts "tcl runtime ok"
TCL
fi

TEST_ROOT="$(mktemp -d)"
DATA_DIR="${TEST_ROOT}/data"
LOG_FILE="${TEST_ROOT}/postgresql.log"
SQL_FILE="${TEST_ROOT}/test.sql"
PORT=55432

mkdir -p "${DATA_DIR}"

"${PACKAGE_DIR}/bin/initdb.exe" --username=postgres --auth-local=trust --auth-host=trust --no-instructions -D "${DATA_DIR}" >/dev/null

POSTGRES_OPTS=(
  "-F"
  "-p" "${PORT}"
  "-c" "listen_addresses=127.0.0.1"
  "-c" "log_destination=stderr"
  "-c" "logging_collector=off"
)

join_postgres_opts() {
  local joined=""
  local arg=""
  for arg in "$@"; do
    if [[ -n "${joined}" ]]; then
      joined+=" "
    fi
    joined+="${arg}"
  done
  printf '%s\n' "${joined}"
}

cleanup() {
  "${PACKAGE_DIR}/bin/pg_ctl.exe" -D "${DATA_DIR}" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${PACKAGE_DIR}/bin/pg_ctl.exe" \
  -D "${DATA_DIR}" \
  -l "${LOG_FILE}" \
  -o "$(join_postgres_opts "${POSTGRES_OPTS[@]}")" \
  -w start >/dev/null || {
    show_log "${LOG_FILE}"
    exit 1
  }

if ! "${PACKAGE_DIR}/bin/psql.exe" -h 127.0.0.1 -p "${PORT}" -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE base_test;" >/dev/null; then
  show_log "${LOG_FILE}"
  exit 1
fi

cat > "${SQL_FILE}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS plpgsql;

CREATE OR REPLACE FUNCTION codex_plpgsql_add(a integer, b integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN a + b;
END
$$;
SQL

if [[ -f "${PACKAGE_DIR}/share/extension/plpython3u.control" ]]; then
  cat >> "${SQL_FILE}" <<'SQL'
CREATE EXTENSION plpython3u;

CREATE OR REPLACE FUNCTION codex_plpython_upper(s text)
RETURNS text
LANGUAGE plpython3u
AS $$
return s.upper()
$$;
SQL
fi

if [[ -f "${PACKAGE_DIR}/share/extension/plperl.control" ]]; then
  cat >> "${SQL_FILE}" <<'SQL'
CREATE EXTENSION plperl;

CREATE OR REPLACE FUNCTION codex_plperl_reverse(s text)
RETURNS text
LANGUAGE plperl
AS $$
return scalar reverse $_[0];
$$;
SQL
fi

if [[ -f "${PACKAGE_DIR}/share/extension/pltcl.control" ]]; then
  cat >> "${SQL_FILE}" <<'SQL'
CREATE EXTENSION pltcl;

CREATE OR REPLACE FUNCTION codex_pltcl_repeat(s text, n integer)
RETURNS text
LANGUAGE pltcl
AS $$
return [string repeat $1 $2]
$$;
SQL
fi

if ! "${PACKAGE_DIR}/bin/psql.exe" -h 127.0.0.1 -p "${PORT}" -U postgres -d base_test -v ON_ERROR_STOP=1 -f "${SQL_FILE}" >/dev/null; then
  show_log "${LOG_FILE}"
  exit 1
fi

[[ "$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SELECT codex_plpgsql_add(20, 22)")" == "42" ]] \
  || { show_log "${LOG_FILE}"; echo "plpgsql function returned unexpected result" >&2; exit 1; }

if [[ -f "${PACKAGE_DIR}/share/extension/plpython3u.control" ]]; then
  [[ "$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SELECT codex_plpython_upper('pgsql')")" == "PGSQL" ]] \
    || { show_log "${LOG_FILE}"; echo "plpython3u function returned unexpected result" >&2; exit 1; }
fi

if [[ -f "${PACKAGE_DIR}/share/extension/plperl.control" ]]; then
  [[ "$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SELECT codex_plperl_reverse('stressed')")" == "desserts" ]] \
    || { show_log "${LOG_FILE}"; echo "plperl function returned unexpected result" >&2; exit 1; }
fi

if [[ -f "${PACKAGE_DIR}/share/extension/pltcl.control" ]]; then
  [[ "$(psql_scalar "${PACKAGE_DIR}/bin/psql.exe" 127.0.0.1 "${PORT}" base_test "SELECT codex_pltcl_repeat('pg', 3)")" == "pgpgpg" ]] \
    || { show_log "${LOG_FILE}"; echo "pltcl function returned unexpected result" >&2; exit 1; }
fi

run_postgresql_jit_test

"${PACKAGE_DIR}/bin/pg_ctl.exe" -D "${DATA_DIR}" -m fast stop >/dev/null
trap - EXIT

echo "PostgreSQL MinGW package test passed: ${PACKAGE_DIR}"
