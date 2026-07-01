#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/tools.sh"

usage() {
  cat <<'EOF'
Usage:
  ./packages/middleware/test_package.sh <package-dir> [redis-port] [minio-port] [etcd-port]

Defaults:
  redis-port: 16379
  minio-port: 19000
  etcd-port: 12379
EOF
}

PACKAGE_DIR="${1:-}"
REDIS_PORT="${2:-16379}"
MINIO_PORT="${3:-19000}"
ETCD_PORT="${4:-12379}"
ETCD_PEER_PORT="$((ETCD_PORT + 1))"

if [[ -z "$PACKAGE_DIR" || "$PACKAGE_DIR" == "-h" || "$PACKAGE_DIR" == "--help" ]]; then
  usage
  exit 0
fi

PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
PACKAGE_TARGET_TRIPLE=""
PATCHELF_STATUS=""
WINSW_STATUS=""
if [[ -f "${PACKAGE_DIR}/manifest.env" ]]; then
  while IFS='=' read -r manifest_key manifest_value; do
    case "$manifest_key" in
      TARGET_TRIPLE) PACKAGE_TARGET_TRIPLE="$manifest_value" ;;
      PATCHELF_STATUS) PATCHELF_STATUS="$manifest_value" ;;
      WINSW_STATUS) WINSW_STATUS="$manifest_value" ;;
    esac
  done <"${PACKAGE_DIR}/manifest.env"
fi

case "$PACKAGE_TARGET_TRIPLE" in
  riscv64-unknown-linux-gnu)
    export ETCD_UNSUPPORTED_ARCH=riscv64
    ;;
  loongarch64-unknown-linux-gnu)
    export ETCD_UNSUPPORTED_ARCH=loong64
    ;;
esac

EXEEXT=""
if [[ -x "${PACKAGE_DIR}/bin/minio.exe" ]]; then
  EXEEXT=".exe"
fi

run_cmd() {
  local binary="$1"
  shift

  if [[ "$EXEEXT" == ".exe" ]]; then
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*)
        "$binary" "$@"
        ;;
      *)
        command -v wine >/dev/null 2>&1 || die "wine is required to test Windows package on this host"
        wine "$binary" "$@"
        ;;
    esac
  else
    "$binary" "$@"
  fi
}

REDIS_SERVER="${PACKAGE_DIR}/bin/redis-server${EXEEXT}"
REDIS_CLI="${PACKAGE_DIR}/bin/redis-cli${EXEEXT}"
MINIO_BIN="${PACKAGE_DIR}/bin/minio${EXEEXT}"
ETCD_BIN="${PACKAGE_DIR}/bin/etcd${EXEEXT}"
ETCDCTL_BIN="${PACKAGE_DIR}/bin/etcdctl${EXEEXT}"
ETCDUTL_BIN="${PACKAGE_DIR}/bin/etcdutl${EXEEXT}"
PATCHELF_BIN="${PACKAGE_DIR}/bin/patchelf"
WINSW_BIN="${PACKAGE_DIR}/bin/winsw.exe"
TEST_DIR="${PACKAGE_DIR}/test-runtime"
MINIO_DATA="${TEST_DIR}/minio-data"
ETCD_DATA="${TEST_DIR}/etcd-data"
MINIO_LOG="${TEST_DIR}/minio.log"
ETCD_LOG="${TEST_DIR}/etcd.log"
REDIS_LOG="${TEST_DIR}/redis.log"
MINIO_PID=""
ETCD_PID=""
REDIS_PID=""
REDIS_EXTRA_ARGS=()

[[ -x "$MINIO_BIN" ]] || die "missing minio binary: ${MINIO_BIN}"
[[ -x "$ETCD_BIN" ]] || die "missing etcd binary: ${ETCD_BIN}"
[[ -x "$ETCDCTL_BIN" ]] || die "missing etcdctl binary: ${ETCDCTL_BIN}"
[[ -x "$ETCDUTL_BIN" ]] || die "missing etcdutl binary: ${ETCDUTL_BIN}"
if [[ "$PATCHELF_STATUS" == "enabled" ]]; then
  [[ -x "$PATCHELF_BIN" ]] || die "missing patchelf binary: ${PATCHELF_BIN}"
fi
if [[ "$WINSW_STATUS" == enabled* ]]; then
  [[ -x "$WINSW_BIN" ]] || die "missing WinSW binary: ${WINSW_BIN}"
  [[ -f "${PACKAGE_DIR}/bin/winsw.xml" ]] || die "missing WinSW smoke-test config: ${PACKAGE_DIR}/bin/winsw.xml"
fi

if [[ "$PACKAGE_TARGET_TRIPLE" == "aarch64-unknown-linux-gnu" ]]; then
  REDIS_EXTRA_ARGS=(--ignore-warnings ARM64-COW-BUG)
fi

rm -rf "$TEST_DIR"
mkdir -p "$MINIO_DATA" "$ETCD_DATA"

cleanup() {
  if [[ -n "$REDIS_PID" ]]; then
    kill "$REDIS_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MINIO_PID" ]]; then
    kill "$MINIO_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ETCD_PID" ]]; then
    kill "$ETCD_PID" >/dev/null 2>&1 || true
  fi
}

dump_logs() {
  local log_path=""

  for log_path in "$REDIS_LOG" "$MINIO_LOG" "$ETCD_LOG"; do
    if [[ -s "$log_path" ]]; then
      echo "-- ${log_path}"
      tail -200 "$log_path" || true
    fi
  done
}

on_exit() {
  local status="$?"

  if [[ "$status" -ne 0 ]]; then
    dump_logs
  fi
  cleanup
}
trap on_exit EXIT

echo "-- minio version"
run_cmd "$MINIO_BIN" --version

echo "-- etcd version"
run_cmd "$ETCD_BIN" --version
run_cmd "$ETCDCTL_BIN" version
run_cmd "$ETCDUTL_BIN" version

if [[ "$PATCHELF_STATUS" == "enabled" ]]; then
  echo "-- patchelf version"
  "$PATCHELF_BIN" --version
fi

if [[ "$WINSW_STATUS" == enabled* ]]; then
  echo "-- winsw version"
  run_cmd "$WINSW_BIN" version
fi

if [[ -x "$REDIS_SERVER" && -x "$REDIS_CLI" ]]; then
  echo "-- redis version"
  run_cmd "$REDIS_SERVER" --version
  run_cmd "$REDIS_CLI" --version

  echo "-- starting redis on 127.0.0.1:${REDIS_PORT}"
  run_cmd "$REDIS_SERVER" \
    --bind 127.0.0.1 \
    --port "$REDIS_PORT" \
    --save "" \
    --appendonly no \
    --daemonize no \
    "${REDIS_EXTRA_ARGS[@]}" \
    >"$REDIS_LOG" 2>&1 &
  REDIS_PID="$!"

  for _ in $(seq 1 30); do
    if run_cmd "$REDIS_CLI" -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
      break
    fi
    sleep 1
  done
  run_cmd "$REDIS_CLI" -h 127.0.0.1 -p "$REDIS_PORT" ping | grep -q PONG
else
  echo "-- redis not present for this target; skipping redis runtime test"
fi

echo "-- starting minio on 127.0.0.1:${MINIO_PORT}"
MINIO_ROOT_USER=minioadmin \
MINIO_ROOT_PASSWORD=minioadmin \
run_cmd "$MINIO_BIN" server "$MINIO_DATA" \
  --address "127.0.0.1:${MINIO_PORT}" \
  --console-address "127.0.0.1:$((MINIO_PORT + 1))" \
  >"$MINIO_LOG" 2>&1 &
MINIO_PID="$!"

for _ in $(seq 1 60); do
  if command -v curl >/dev/null 2>&1 \
      && curl --connect-timeout 2 --max-time 5 -fsS "http://127.0.0.1:${MINIO_PORT}/minio/health/live" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if command -v curl >/dev/null 2>&1; then
  curl --connect-timeout 5 --max-time 10 -fsS "http://127.0.0.1:${MINIO_PORT}/minio/health/live" >/dev/null
fi

echo "-- starting etcd on 127.0.0.1:${ETCD_PORT}"
run_cmd "$ETCD_BIN" \
  --name default \
  --data-dir "$ETCD_DATA" \
  --listen-client-urls "http://127.0.0.1:${ETCD_PORT}" \
  --advertise-client-urls "http://127.0.0.1:${ETCD_PORT}" \
  --listen-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-advertise-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-cluster "default=http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-cluster-token middleware-test \
  --initial-cluster-state new \
  >"$ETCD_LOG" 2>&1 &
ETCD_PID="$!"

for _ in $(seq 1 60); do
  if run_cmd "$ETCDCTL_BIN" --endpoints "http://127.0.0.1:${ETCD_PORT}" endpoint health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
run_cmd "$ETCDCTL_BIN" --endpoints "http://127.0.0.1:${ETCD_PORT}" endpoint health
run_cmd "$ETCDCTL_BIN" --endpoints "http://127.0.0.1:${ETCD_PORT}" put middleware-test ok >/dev/null
run_cmd "$ETCDCTL_BIN" --endpoints "http://127.0.0.1:${ETCD_PORT}" get middleware-test | grep -q ok

echo "-- middleware package test passed"
