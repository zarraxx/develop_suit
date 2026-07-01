#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./packages/postgresql18_dist/test_service_linux.sh --archive=<tar.xz> \
    --oracle-basic-archive=<zip> --db2-cli-archive=<tar.gz>
  ./packages/postgresql18_dist/test_service_linux.sh --package-dir=<dir> \
    --oracle-basic-archive=<zip> --db2-cli-archive=<tar.gz>

Options:
  --archive=<tar.xz>                PostgreSQL 18 dist Linux package
  --package-dir=<dir>               Extracted PostgreSQL 18 dist package
  --oracle-basic-archive=<zip>      Oracle Instant Client Basic archive
  --db2-cli-archive=<archive>       IBM DB2 CLI/ODBC archive
  --oracle-image=<image>            Oracle container image
  --without-db2-fdw                 Do not install DB2 CLI or activate db2_fdw
  -h, --help                        Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

abs_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s\n' "$(pwd)/$path" ;;
  esac
}

ARCHIVE=""
PACKAGE_DIR=""
ORACLE_BASIC_ARCHIVE=""
DB2_CLI_ARCHIVE=""
ORACLE_IMAGE="${ORACLE_DOCKER_IMAGE:-docker.io/gvenzl/oracle-free:23-slim-faststart}"
WITH_DB2_FDW=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive=*) ARCHIVE="${1#*=}" ;;
    --archive) shift; [[ $# -gt 0 ]] || die "--archive requires a value"; ARCHIVE="$1" ;;
    --package-dir=*) PACKAGE_DIR="${1#*=}" ;;
    --package-dir) shift; [[ $# -gt 0 ]] || die "--package-dir requires a value"; PACKAGE_DIR="$1" ;;
    --oracle-basic-archive=*) ORACLE_BASIC_ARCHIVE="${1#*=}" ;;
    --oracle-basic-archive) shift; [[ $# -gt 0 ]] || die "--oracle-basic-archive requires a value"; ORACLE_BASIC_ARCHIVE="$1" ;;
    --db2-cli-archive=*) DB2_CLI_ARCHIVE="${1#*=}" ;;
    --db2-cli-archive) shift; [[ $# -gt 0 ]] || die "--db2-cli-archive requires a value"; DB2_CLI_ARCHIVE="$1" ;;
    --oracle-image=*) ORACLE_IMAGE="${1#*=}" ;;
    --oracle-image) shift; [[ $# -gt 0 ]] || die "--oracle-image requires a value"; ORACLE_IMAGE="$1" ;;
    --without-db2-fdw) WITH_DB2_FDW=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -z "$ARCHIVE" || -z "$PACKAGE_DIR" ]] || die "--archive and --package-dir are mutually exclusive"
[[ -n "$ARCHIVE" || -n "$PACKAGE_DIR" ]] || die "--archive or --package-dir is required"
[[ -n "$ORACLE_BASIC_ARCHIVE" ]] || die "--oracle-basic-archive is required"
if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  [[ -n "$DB2_CLI_ARCHIVE" ]] || die "--db2-cli-archive is required unless --without-db2-fdw is used"
fi

require_command docker
require_command curl
require_command tar
require_command sudo
require_command systemctl

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgresql18-dist-service.XXXXXX")"
DATA_DIR="${TEST_ROOT}/data"
VENDOR_DIR="${TEST_ROOT}/vendor"
SERVICE_NAME="postgresql18-ci-${RANDOM}"
PG_PORT="$((57432 + (RANDOM % 1000)))"
ORACLE_PORT="$((11521 + (RANDOM % 1000)))"
ORACLE_CONTAINER="postgresql18-oracle-ci-${RANDOM}"
ORACLE_USER="FDWUSER"
ORACLE_PASSWORD="FdwPassw0rd123"
ORACLE_SYS_PASSWORD="OraclePassw0rd123"

cleanup() {
  set +e
  if [[ -n "${PACKAGE_DIR:-}" && -x "${PACKAGE_DIR}/uninstall_service.sh" ]]; then
    sudo "${PACKAGE_DIR}/uninstall_service.sh" "$SERVICE_NAME" >/dev/null 2>&1
  fi
  docker rm -f "$ORACLE_CONTAINER" >/dev/null 2>&1
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

if [[ -n "$ARCHIVE" ]]; then
  ARCHIVE="$(abs_path "$ARCHIVE")"
  [[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"
  tar -xf "$ARCHIVE" -C "$TEST_ROOT"
  PACKAGE_DIR="$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | head -n 1)"
fi

[[ -n "$PACKAGE_DIR" && -d "$PACKAGE_DIR" ]] || die "package directory not found"
PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
ORACLE_BASIC_ARCHIVE="$(abs_path "$ORACLE_BASIC_ARCHIVE")"
[[ -f "$ORACLE_BASIC_ARCHIVE" ]] || die "Oracle archive not found: $ORACLE_BASIC_ARCHIVE"
if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  DB2_CLI_ARCHIVE="$(abs_path "$DB2_CLI_ARCHIVE")"
  [[ -f "$DB2_CLI_ARCHIVE" ]] || die "DB2 CLI archive not found: $DB2_CLI_ARCHIVE"
fi

for path in \
  "${PACKAGE_DIR}/bin/postgres" \
  "${PACKAGE_DIR}/bin/psql" \
  "${PACKAGE_DIR}/install_service.sh" \
  "${PACKAGE_DIR}/uninstall_service.sh" \
  "${PACKAGE_DIR}/install_external_dependencies.sh" \
  "${PACKAGE_DIR}/share/extension/oracle_fdw.control"; do
  [[ -e "$path" ]] || die "missing path: $path"
done
if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  [[ -e "${PACKAGE_DIR}/share/extension/db2_fdw.control" ]] || die "missing path: ${PACKAGE_DIR}/share/extension/db2_fdw.control"
fi

psql_service() {
  "${PACKAGE_DIR}/bin/psql" -h /tmp -p "$PG_PORT" -U postgres "$@"
}

wait_postgresql() {
  local attempt=""
  for attempt in $(seq 1 60); do
    if psql_service -d postgres -Atqc "SELECT 1;" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  sudo systemctl status "$SERVICE_NAME" --no-pager || true
  sudo journalctl -u "$SERVICE_NAME" --no-pager -n 200 || true
  die "PostgreSQL service did not become ready"
}

wait_oracle() {
  local attempt=""
  for attempt in $(seq 1 180); do
    if docker exec "$ORACLE_CONTAINER" bash -lc \
      "printf '%s\n' 'select 1 from dual;' 'exit' | sqlplus -S ${ORACLE_USER}/${ORACLE_PASSWORD}@FREEPDB1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  docker logs "$ORACLE_CONTAINER" || true
  die "Oracle container did not become ready"
}

log "starting Oracle container: ${ORACLE_IMAGE}"
docker pull "$ORACLE_IMAGE"
docker run -d \
  --name "$ORACLE_CONTAINER" \
  -p "${ORACLE_PORT}:1521" \
  -e "ORACLE_PASSWORD=${ORACLE_SYS_PASSWORD}" \
  -e "APP_USER=${ORACLE_USER}" \
  -e "APP_USER_PASSWORD=${ORACLE_PASSWORD}" \
  "$ORACLE_IMAGE" >/dev/null

log "installing PostgreSQL systemd service"
sudo "${PACKAGE_DIR}/install_service.sh" \
  "$DATA_DIR" \
  "$SERVICE_NAME" \
  postgres \
  127.0.0.1 \
  "$PG_PORT" \
  127.0.0.1/32

if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  log "installing Oracle and DB2 runtime clients"
else
  log "installing Oracle runtime client"
fi
external_dependency_args=(
  "--oracle-basic-archive=${ORACLE_BASIC_ARCHIVE}"
  "--prefix=${VENDOR_DIR}"
  "--service-name=${SERVICE_NAME}"
)
if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  external_dependency_args+=("--db2-cli-archive=${DB2_CLI_ARCHIVE}")
fi
sudo "${PACKAGE_DIR}/install_external_dependencies.sh" "${external_dependency_args[@]}"

log "starting PostgreSQL service"
sudo systemctl start "$SERVICE_NAME"
wait_postgresql

log "waiting for Oracle service"
wait_oracle

log "initializing Oracle test data"
docker exec -i "$ORACLE_CONTAINER" bash -lc "sqlplus -S ${ORACLE_USER}/${ORACLE_PASSWORD}@FREEPDB1" <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE fdw_numbers PURGE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN
      RAISE;
    END IF;
END;
/
CREATE TABLE fdw_numbers (
  id NUMBER(10) PRIMARY KEY,
  label VARCHAR2(64)
);
INSERT INTO fdw_numbers VALUES (1, 'one');
INSERT INTO fdw_numbers VALUES (2, 'two');
COMMIT;
EXIT
SQL

if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  log "activating oracle_fdw and db2_fdw"
else
  log "activating oracle_fdw"
fi
psql_service -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE DATABASE dist_service_test;
\connect dist_service_test
CREATE EXTENSION oracle_fdw;
CREATE SERVER oracle_ci FOREIGN DATA WRAPPER oracle_fdw
  OPTIONS (dbserver '//127.0.0.1:${ORACLE_PORT}/FREEPDB1');
CREATE USER MAPPING FOR postgres SERVER oracle_ci
  OPTIONS (user '${ORACLE_USER}', password '${ORACLE_PASSWORD}');
CREATE FOREIGN TABLE oracle_fdw_numbers (
  id numeric(10),
  label varchar(64)
) SERVER oracle_ci OPTIONS (schema '${ORACLE_USER}', table 'FDW_NUMBERS');
SELECT count(*) AS oracle_rows FROM oracle_fdw_numbers;
SQL

if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  psql_service -d dist_service_test -v ON_ERROR_STOP=1 -c "CREATE EXTENSION db2_fdw;"
fi

oracle_count="$(psql_service -d dist_service_test -Atqc "SELECT count(*) FROM oracle_fdw_numbers;")"
[[ "$oracle_count" == "2" ]] || die "unexpected oracle_fdw row count: ${oracle_count}"

if [[ "$WITH_DB2_FDW" -eq 1 ]]; then
  db2_count="$(psql_service -d dist_service_test -Atqc "SELECT count(*) FROM pg_extension WHERE extname = 'db2_fdw';")"
  [[ "$db2_count" == "1" ]] || die "db2_fdw extension was not activated"
fi

oracle_ext_count="$(psql_service -d dist_service_test -Atqc "SELECT count(*) FROM pg_extension WHERE extname = 'oracle_fdw';")"
[[ "$oracle_ext_count" == "1" ]] || die "oracle_fdw extension was not activated"

log "stopping and uninstalling PostgreSQL service"
sudo systemctl stop "$SERVICE_NAME"
sudo "${PACKAGE_DIR}/uninstall_service.sh" "$SERVICE_NAME"
if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${SERVICE_NAME}.service"; then
  die "service still installed after uninstall: ${SERVICE_NAME}"
fi

trap - EXIT
docker rm -f "$ORACLE_CONTAINER" >/dev/null 2>&1
rm -rf "$TEST_ROOT"

echo "PostgreSQL 18 dist Linux service test passed"
