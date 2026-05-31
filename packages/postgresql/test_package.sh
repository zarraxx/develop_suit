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
  ./packages/postgresql/test_package.sh --target=<target> --package-dir=<dir>
  ./packages/postgresql/test_package.sh --target=<target> --archive=<tar.xz>

Options:
  --target=<target>       PostgreSQL package target
  --arch=<target>         Alias for --target
  --package-dir=<dir>     Extracted PostgreSQL package prefix
  --archive=<tar.xz>      PostgreSQL package archive to extract and test
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
resolve_target "$TARGET" "PostgreSQL package test target"

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

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "missing file: ${path}"
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || die "missing executable: ${path}"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "missing directory: ${path}"
}

language_enabled() {
  local language_name="$1"
  local readme_path="${PACKAGE_DIR}/README.postgresql"
  local expected_line=""

  [[ -f "${readme_path}" ]] || return 1

  case "${language_name}" in
    perl) expected_line="Perl: yes" ;;
    python) expected_line="Python: yes" ;;
    tcl) expected_line="Tcl: yes" ;;
    *) die "unknown language name: ${language_name}" ;;
  esac

  grep -Fq "${expected_line}" "${readme_path}"
}

require_configure_flag() {
  local configure_output="$1"
  local expected_flag="$2"

  [[ -n "$configure_output" ]] || return 0
  [[ "$configure_output" == *"$expected_flag"* ]] || die "missing configure flag: ${expected_flag}"
}

check_file_target() {
  local path="$1"
  local expected="$2"

  command -v file >/dev/null 2>&1 || return 0
  file -L "$path"
  file -L "$path" | grep -qi "$expected" || die "unexpected file target for ${path}; expected ${expected}"
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

setup_runtime_env() {
  local perl_config=""
  local perl_archlib=""
  local perl_privlib=""

  export PATH="${PACKAGE_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${PACKAGE_DIR}/lib:${LD_LIBRARY_PATH:-}"

  if [[ -d "${PACKAGE_DIR}/lib/python3.14" ]]; then
    export PYTHONHOME="${PACKAGE_DIR}"
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

  if [[ -d "${PACKAGE_DIR}/lib/tcl8.6" ]]; then
    export TCL_LIBRARY="${PACKAGE_DIR}/lib/tcl8.6"
  fi
}

run_postgresql_integration_test() {
  local initdb_bin="$1"
  local pg_ctl_bin="$2"
  local psql_bin="$3"
  local data_dir="$4"
  local socket_dir="$5"
  local log_file="$6"
  local port="$7"

  rm -rf "$data_dir" "$socket_dir"
  mkdir -p "$data_dir" "$socket_dir"

  cleanup_cluster() {
    if [[ -n "${pg_ctl_bin:-}" && -d "$data_dir" ]]; then
      "${pg_ctl_bin}" -D "$data_dir" -m immediate stop >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_cluster EXIT

  "${initdb_bin}" \
    --username=postgres \
    --auth-local=trust \
    --auth-host=trust \
    --no-instructions \
    -D "$data_dir" >/dev/null

  "${pg_ctl_bin}" \
    -D "$data_dir" \
    -l "$log_file" \
    -o "-F -k '${socket_dir}' -p ${port} -c listen_addresses=''" \
    -w start >/dev/null

  "${psql_bin}" \
    -h "$socket_dir" \
    -p "$port" \
    -U postgres \
    -d postgres \
    -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS plpgsql;
CREATE EXTENSION plpython3u;
CREATE EXTENSION plperl;
CREATE EXTENSION pltcl;

CREATE OR REPLACE FUNCTION codex_plpgsql_add(a integer, b integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN a + b;
END
$$;

CREATE OR REPLACE FUNCTION codex_plpython_upper(s text)
RETURNS text
LANGUAGE plpython3u
AS $$
return s.upper()
$$;

CREATE OR REPLACE FUNCTION codex_plperl_reverse(s text)
RETURNS text
LANGUAGE plperl
AS $$
return scalar reverse $_[0];
$$;

CREATE OR REPLACE FUNCTION codex_pltcl_repeat(s text, n integer)
RETURNS text
LANGUAGE pltcl
AS $$
return [string repeat $1 $2]
$$;
SQL

  [[ "$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SELECT codex_plpgsql_add(20, 22)")" == "42" ]] \
    || die "plpgsql function returned unexpected result"
  [[ "$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SELECT codex_plpython_upper('pgsql')")" == "PGSQL" ]] \
    || die "plpython3u function returned unexpected result"
  [[ "$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SELECT codex_plperl_reverse('stressed')")" == "desserts" ]] \
    || die "plperl function returned unexpected result"
  [[ "$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SELECT codex_pltcl_repeat('pg', 3)")" == "pgpgpg" ]] \
    || die "pltcl function returned unexpected result"

  "${pg_ctl_bin}" -D "$data_dir" -m fast stop >/dev/null
  trap - EXIT
}

require_dir "${PACKAGE_DIR}/bin"
require_dir "${PACKAGE_DIR}/include"
require_dir "${PACKAGE_DIR}/lib"
require_dir "${PACKAGE_DIR}/share/extension"
require_file "${PACKAGE_DIR}/README.postgresql"
require_file "${PACKAGE_DIR}/share/extension/plpgsql.control"

if language_enabled python; then
  require_file "${PACKAGE_DIR}/share/extension/plpython3u.control"
fi
if language_enabled perl; then
  require_file "${PACKAGE_DIR}/share/extension/plperl.control"
fi
if language_enabled tcl; then
  require_file "${PACKAGE_DIR}/share/extension/pltcl.control"
fi

case "$TARGET_KIND" in
  linux)
    setup_runtime_env

    require_file "${PACKAGE_DIR}/bin/postgres"
    require_file "${PACKAGE_DIR}/bin/psql"
    require_file "${PACKAGE_DIR}/bin/initdb"
    require_file "${PACKAGE_DIR}/bin/pg_ctl"

    INITDB_BIN="$(find_package_executable initdb)"
    PG_CTL_BIN="$(find_package_executable pg_ctl)"
    PSQL_BIN="$(find_package_executable psql)"
    POSTGRES_BIN="$(find_package_executable postgres)"
    PG_CONFIG_BIN="$(find_package_executable pg_config)"
    PYTHON_BIN="$(find_package_executable python3 'python3.[0-9]*' 'python[0-9].[0-9]*' 'python')"
    PERL_BIN="$(find_package_executable perl 'perl[0-9]*')"
    TCLSH_BIN="$(find_package_executable tclsh8.6.bin 'tclsh*.bin' 'tclsh*')"

    require_executable "${INITDB_BIN}"
    require_executable "${PG_CTL_BIN}"
    require_executable "${PSQL_BIN}"
    require_executable "${POSTGRES_BIN}"
    require_executable "${PG_CONFIG_BIN}"
    require_executable "${PYTHON_BIN}"
    require_executable "${PERL_BIN}"
    require_executable "${TCLSH_BIN}"

    if [[ "$ARCH" == "x86_64" ]]; then
      echo "Running PostgreSQL x86_64 integration test"

      PG_CONFIGURE_OUTPUT="$("${PG_CONFIG_BIN}" --configure)"
      if [[ -n "${PG_CONFIGURE_OUTPUT}" ]]; then
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-icu"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-ldap"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-openssl"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-libnuma"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-liburing"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-perl"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-python"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-tcl"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-pam"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-libxml"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-libxslt"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-gssapi"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-zlib"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-readline"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-lz4"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-zstd"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-systemd"
        require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-uuid=e2fs"
      fi

      "${PYTHON_BIN}" -c 'print("python runtime ok")'
      "${PERL_BIN}" -e 'print "perl runtime ok\n";'
      "${TCLSH_BIN}" <<'TCL'
puts "tcl runtime ok"
TCL

      TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgresql-test.XXXXXX")"
      DATA_DIR="${TEST_ROOT}/data"
      SOCKET_DIR="${TEST_ROOT}/socket"
      LOG_FILE="${TEST_ROOT}/postgresql.log"
      PORT=$((55432 + (RANDOM % 1000)))
      run_postgresql_integration_test "${INITDB_BIN}" "${PG_CTL_BIN}" "${PSQL_BIN}" "${DATA_DIR}" "${SOCKET_DIR}" "${LOG_FILE}" "${PORT}"

      check_file_target "${POSTGRES_BIN}" "x86-64"
      check_file_target "${PYTHON_BIN}" "x86-64"
      check_file_target "${PERL_BIN}" "x86-64"
      check_file_target "${TCLSH_BIN}" "x86-64"
    elif [[ "$ARCH" == "aarch64" ]]; then
      check_file_target "${POSTGRES_BIN}" "aarch64"
    elif [[ "$ARCH" == "riscv64" ]]; then
      check_file_target "${POSTGRES_BIN}" "riscv"
    elif [[ "$ARCH" == "loongarch64" ]]; then
      check_file_target "${POSTGRES_BIN}" "loongarch"
    fi
    ;;
  mingw)
    require_file "${PACKAGE_DIR}/bin/postgres.exe"
    require_file "${PACKAGE_DIR}/bin/psql.exe"
    require_file "${PACKAGE_DIR}/bin/initdb.exe"
    require_file "${PACKAGE_DIR}/bin/pg_ctl.exe"
    check_file_target "${PACKAGE_DIR}/bin/postgres.exe" "PE32+"
    ;;
  *)
    die "unsupported target kind: ${TARGET_KIND}"
    ;;
esac

echo "PostgreSQL package test passed: ${PACKAGE_TRIPLE}"
