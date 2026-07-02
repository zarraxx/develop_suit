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
PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"

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

require_pg_config_path() {
  local pg_config_bin="$1"
  local option="$2"
  local expected_path="$3"
  local actual_path=""

  actual_path="$("$pg_config_bin" "$option")"
  [[ "$actual_path" == "$expected_path" ]] \
    || die "${option} returned ${actual_path}, expected ${expected_path}"
}

require_pg_config_output_contains() {
  local pg_config_bin="$1"
  local option="$2"
  local expected_text="$3"
  local actual_output=""

  actual_output="$("$pg_config_bin" "$option")"
  [[ "$actual_output" == *"$expected_text"* ]] \
    || die "${option} returned ${actual_output}, expected it to contain ${expected_text}"
}

require_pg_config_output_has_no_opt_package_prefix() {
  local pg_config_bin="$1"
  local option="$2"
  local actual_output=""

  actual_output="$("$pg_config_bin" "$option")"
  if [[ "$actual_output" =~ /opt/[^[:space:]]+-${PACKAGE_TRIPLE} ]]; then
    die "${option} returned build-time package prefix in: ${actual_output}"
  fi
}

check_relocatable_pg_config() {
  local pg_config_bin="$1"

  require_executable "$pg_config_bin"
  require_pg_config_path "$pg_config_bin" --includedir "${PACKAGE_DIR}/include"
  require_pg_config_path "$pg_config_bin" --includedir-server "${PACKAGE_DIR}/include/server"
  require_pg_config_path "$pg_config_bin" --libdir "${PACKAGE_DIR}/lib"
  require_pg_config_path "$pg_config_bin" --pkglibdir "${PACKAGE_DIR}/lib"
  require_pg_config_path "$pg_config_bin" --pgxs "${PACKAGE_DIR}/lib/pgxs/src/makefiles/pgxs.mk"
  require_pg_config_output_contains "$pg_config_bin" --cflags "-I${PACKAGE_DIR}/include"
  require_pg_config_output_contains "$pg_config_bin" --ldflags "-L${PACKAGE_DIR}/lib"
  require_pg_config_output_has_no_opt_package_prefix "$pg_config_bin" --cflags
  require_pg_config_output_has_no_opt_package_prefix "$pg_config_bin" --ldflags
}

package_has_llvm_jit() {
  [[ -f "${PACKAGE_DIR}/lib/llvmjit.so" ]]
}

can_run_linux_target() {
  local machine=""

  machine="$(uname -m)"
  case "$ARCH:$machine" in
    x86_64:x86_64|aarch64:aarch64|riscv64:riscv64|loongarch64:loongarch64)
      return 0
      ;;
  esac
  return 1
}

POSTGRESQL_TEST_PG_CTL_BIN=""
POSTGRESQL_TEST_DATA_DIR=""

cleanup_postgresql_test_cluster() {
  [[ -n "$POSTGRESQL_TEST_PG_CTL_BIN" && -d "$POSTGRESQL_TEST_DATA_DIR" ]] || return 0
  "${POSTGRESQL_TEST_PG_CTL_BIN}" -D "$POSTGRESQL_TEST_DATA_DIR" -m immediate stop >/dev/null 2>&1 || true
}

check_llvm_jit_runtime_dependencies() {
  local dynamic_entries=""
  local ldd_output=""

  package_has_llvm_jit || return 0

  if command -v readelf >/dev/null 2>&1; then
    dynamic_entries="$(readelf -d "${PACKAGE_DIR}/lib/llvmjit.so" 2>&1)" \
      || die "failed to inspect llvmjit.so dynamic entries: ${dynamic_entries}"
    if ! grep -q 'Shared library: \[libLLVM\.so' <<<"$dynamic_entries"; then
      die "llvmjit.so is not linked against libLLVM: ${dynamic_entries}"
    fi
  fi

  command -v ldd >/dev/null 2>&1 || return 0
  can_run_linux_target || return 0

  if ! ldd_output="$(LD_LIBRARY_PATH="${PACKAGE_DIR}/lib:${LD_LIBRARY_PATH:-}" ldd "${PACKAGE_DIR}/lib/llvmjit.so" 2>&1)"; then
    die "failed to inspect llvmjit.so runtime dependencies: ${ldd_output}"
  fi
  if grep -q "not found" <<<"$ldd_output"; then
    die "llvmjit.so has missing runtime dependencies: ${ldd_output}"
  fi
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

run_postgresql_jit_test() {
  local psql_bin="$1"
  local socket_dir="$2"
  local port="$3"
  local jit_setting=""
  local jit_provider=""
  local jit_available=""
  local jit_sum=""

  package_has_llvm_jit || return 0

  echo "Running PostgreSQL LLVM JIT test"

  jit_setting="$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SHOW jit")"
  [[ "$jit_setting" == "on" ]] || die "unexpected jit setting: ${jit_setting}"

  jit_provider="$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SHOW jit_provider")"
  [[ "$jit_provider" == "llvmjit" ]] || die "unexpected jit_provider: ${jit_provider}"

  jit_available="$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -Atqc "SELECT pg_jit_available()")"
  [[ "$jit_available" == "t" ]] || die "pg_jit_available() returned: ${jit_available}"

  jit_sum="$("${psql_bin}" -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET jit = on;
SET jit_above_cost = 0;
SET jit_inline_above_cost = 0;
SET jit_optimize_above_cost = 0;
SELECT sum((i::bigint * i::bigint)) FROM generate_series(1, 10000) AS g(i);
SQL
)"
  [[ "$jit_sum" == "333383335000" ]] || die "JIT query returned unexpected result: ${jit_sum}"
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

  POSTGRESQL_TEST_PG_CTL_BIN="$pg_ctl_bin"
  POSTGRESQL_TEST_DATA_DIR="$data_dir"
  trap cleanup_postgresql_test_cluster EXIT

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

  run_postgresql_jit_test "$psql_bin" "$socket_dir" "$port"

  "${pg_ctl_bin}" -D "$data_dir" -m fast stop >/dev/null
  POSTGRESQL_TEST_PG_CTL_BIN=""
  POSTGRESQL_TEST_DATA_DIR=""
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
    check_relocatable_pg_config "${PG_CONFIG_BIN}"

    if [[ "$ARCH" == "x86_64" ]]; then
      echo "Checking PostgreSQL x86_64 runtime metadata"

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
        if package_has_llvm_jit; then
          require_configure_flag "${PG_CONFIGURE_OUTPUT}" "--with-llvm"
        fi
      fi

      "${PYTHON_BIN}" -c 'print("python runtime ok")'
      "${PERL_BIN}" -e 'print "perl runtime ok\n";'
      "${TCLSH_BIN}" <<'TCL'
puts "tcl runtime ok"
TCL
    fi

    if package_has_llvm_jit; then
      check_llvm_jit_runtime_dependencies
    fi

    if [[ "$ARCH" == "x86_64" ]] || { package_has_llvm_jit && can_run_linux_target; }; then
      echo "Running PostgreSQL ${ARCH} integration test"
      TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgresql-test.XXXXXX")"
      DATA_DIR="${TEST_ROOT}/data"
      SOCKET_DIR="${TEST_ROOT}/socket"
      LOG_FILE="${TEST_ROOT}/postgresql.log"
      PORT=$((55432 + (RANDOM % 1000)))
      run_postgresql_integration_test "${INITDB_BIN}" "${PG_CTL_BIN}" "${PSQL_BIN}" "${DATA_DIR}" "${SOCKET_DIR}" "${LOG_FILE}" "${PORT}"
    fi

    if [[ "$ARCH" == "x86_64" ]]; then
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
    require_file "${PACKAGE_DIR}/bin/pg_config.exe"
    check_relocatable_pg_config "${PACKAGE_DIR}/bin/pg_config"
    check_file_target "${PACKAGE_DIR}/bin/postgres.exe" "PE32+"
    ;;
  *)
    die "unsupported target kind: ${TARGET_KIND}"
    ;;
esac

echo "PostgreSQL package test passed: ${PACKAGE_TRIPLE}"
