#!/usr/bin/env bash

set -euo pipefail

PACKAGE_DIR="${1:-}"

if [[ -z "$PACKAGE_DIR" || "$PACKAGE_DIR" == "-h" || "$PACKAGE_DIR" == "--help" ]]; then
  echo "Usage: ./packages/middleware/test_service_linux.sh <package-dir>" >&2
  exit 1
fi

PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
REDIS_SERVICE="middleware-redis-ci"
MINIO_SERVICE="middleware-minio-ci"
REDIS_DATA_DIR="/tmp/${REDIS_SERVICE}-data"
MINIO_DATA_DIR="/tmp/${MINIO_SERVICE}-data"
REDIS_PASSWORD="middleware-ci-secret"
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD="minioadmin"

die() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  if [[ -x "${PACKAGE_DIR}/uninstall_redis_service.sh" ]]; then
    "${PACKAGE_DIR}/uninstall_redis_service.sh" "$REDIS_SERVICE" >/dev/null 2>&1 || true
  fi
  if [[ -x "${PACKAGE_DIR}/uninstall_minio_service.sh" ]]; then
    "${PACKAGE_DIR}/uninstall_minio_service.sh" "$MINIO_SERVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$REDIS_DATA_DIR" "$MINIO_DATA_DIR"
}

wait_for_redis() {
  for _ in $(seq 1 60); do
    if "${PACKAGE_DIR}/bin/redis-cli" -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_minio() {
  for _ in $(seq 1 90); do
    if curl --connect-timeout 2 --max-time 5 -fsS "http://127.0.0.1:9000/minio/health/live" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

trap cleanup EXIT

[[ -x "${PACKAGE_DIR}/install_redis_service.sh" ]] || die "missing install_redis_service.sh"
[[ -x "${PACKAGE_DIR}/uninstall_redis_service.sh" ]] || die "missing uninstall_redis_service.sh"
[[ -x "${PACKAGE_DIR}/install_minio_service.sh" ]] || die "missing install_minio_service.sh"
[[ -x "${PACKAGE_DIR}/uninstall_minio_service.sh" ]] || die "missing uninstall_minio_service.sh"
[[ -x "${PACKAGE_DIR}/bin/redis-server" ]] || die "missing redis-server"
[[ -x "${PACKAGE_DIR}/bin/redis-cli" ]] || die "missing redis-cli"
[[ -x "${PACKAGE_DIR}/bin/minio" ]] || die "missing minio"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

cleanup

echo "-- installing Redis service"
"${PACKAGE_DIR}/install_redis_service.sh" "$REDIS_SERVICE" "$REDIS_DATA_DIR" "$REDIS_PASSWORD" root
systemctl start "$REDIS_SERVICE"
wait_for_redis || {
  systemctl status "$REDIS_SERVICE" --no-pager || true
  journalctl -u "$REDIS_SERVICE" --no-pager -n 100 || true
  die "Redis service did not become ready"
}
"${PACKAGE_DIR}/bin/redis-cli" -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD" set middleware-service-ci ok >/dev/null
"${PACKAGE_DIR}/bin/redis-cli" -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD" get middleware-service-ci | grep -q ok
"${PACKAGE_DIR}/uninstall_redis_service.sh" "$REDIS_SERVICE"
! systemctl is-active --quiet "$REDIS_SERVICE" || die "Redis service is still active after uninstall"

echo "-- installing MinIO service"
"${PACKAGE_DIR}/install_minio_service.sh" "$MINIO_SERVICE" "$MINIO_DATA_DIR" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" root
systemctl start "$MINIO_SERVICE"
wait_for_minio || {
  systemctl status "$MINIO_SERVICE" --no-pager || true
  journalctl -u "$MINIO_SERVICE" --no-pager -n 100 || true
  die "MinIO service did not become ready"
}
curl --connect-timeout 5 --max-time 10 -fsS "http://127.0.0.1:9000/minio/health/live" >/dev/null
"${PACKAGE_DIR}/uninstall_minio_service.sh" "$MINIO_SERVICE"
! systemctl is-active --quiet "$MINIO_SERVICE" || die "MinIO service is still active after uninstall"

echo "-- middleware Linux service test passed"
