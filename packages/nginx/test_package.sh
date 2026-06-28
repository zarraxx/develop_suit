#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/tools.sh"

usage() {
  cat <<'EOF'
Usage:
  ./packages/nginx/test_package.sh <package-dir> [web-port] [proxy-port]

Defaults:
  web-port: 18080
  proxy-port: 7890

The test starts package nginx, checks the welcome page, then checks CONNECT
forward proxying with package bin/curl_static.
EOF
}

PACKAGE_DIR="${1:-}"
WEB_PORT="${2:-18080}"
PROXY_PORT="${3:-7890}"

if [[ -z "$PACKAGE_DIR" || "$PACKAGE_DIR" == "-h" || "$PACKAGE_DIR" == "--help" ]]; then
  usage
  exit 0
fi

PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
EXEEXT=""
if [[ -x "${PACKAGE_DIR}/sbin/nginx.exe" ]]; then
  EXEEXT=".exe"
fi
NGINX_BIN="${PACKAGE_DIR}/sbin/nginx${EXEEXT}"
CURL_BIN="${PACKAGE_DIR}/bin/curl_static${EXEEXT}"
TEST_DIR="${PACKAGE_DIR}/test-runtime"
TEST_CONF="${TEST_DIR}/nginx-test.conf"

[[ -x "$NGINX_BIN" ]] || die "missing nginx binary: ${NGINX_BIN}"
[[ -x "$CURL_BIN" ]] || die "missing curl_static binary: ${CURL_BIN}"

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/logs" "$TEST_DIR/run"

nginx_path() {
  local path="$1"

  if [[ "$EXEEXT" == ".exe" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    printf '%s\n' "$path"
  fi
}

NGINX_PREFIX="$(nginx_path "${PACKAGE_DIR}/")"
NGINX_TEST_DIR="$(nginx_path "$TEST_DIR")"
NGINX_CONF_MIME="$(nginx_path "${PACKAGE_DIR}/conf/mime.types")"
NGINX_HTML_DIR="$(nginx_path "${PACKAGE_DIR}/html")"

cat >"$TEST_CONF" <<EOF
worker_processes 1;
error_log ${NGINX_TEST_DIR}/logs/error.log info;
pid ${NGINX_TEST_DIR}/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include ${NGINX_CONF_MIME};
    default_type application/octet-stream;
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;

    access_log ${TEST_DIR}/logs/access.log;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 127.0.0.1:${WEB_PORT};
        server_name localhost;

        location / {
            root ${NGINX_HTML_DIR};
            index index.html index.htm;
        }
    }

    server {
        listen 127.0.0.1:${PROXY_PORT};
        server_name localhost;

        proxy_connect;
        proxy_connect_allow 443 563;
        proxy_connect_connect_timeout 10s;
        proxy_connect_read_timeout 20s;
        proxy_connect_send_timeout 20s;

        location / {
            proxy_pass http://\$host\$request_uri;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF

cleanup() {
  if [[ -f "${TEST_DIR}/run/nginx.pid" ]]; then
    "$NGINX_BIN" -p "$NGINX_PREFIX" -c "$TEST_CONF" -s quit >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$NGINX_BIN" -p "$NGINX_PREFIX" -c "$TEST_CONF" -e stderr -t
"$NGINX_BIN" -p "$NGINX_PREFIX" -c "$TEST_CONF" -e stderr
sleep 1

echo "-- curl_static version"
"$CURL_BIN" -V

echo "-- testing nginx welcome page on http://127.0.0.1:${WEB_PORT}"
"$CURL_BIN" -fsS "http://127.0.0.1:${WEB_PORT}/" | grep -q "Welcome to nginx"

echo "-- testing forward proxy on http://127.0.0.1:${PROXY_PORT}"
"$CURL_BIN" -k -v -x "http://127.0.0.1:${PROXY_PORT}" "https://www.google.com" -o /dev/null

echo "-- nginx package test passed"
