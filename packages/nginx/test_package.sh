#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/tools.sh"

usage() {
  cat <<'EOF'
Usage:
  ./packages/nginx/test_package.sh <package-dir> [web-port] [proxy-port] [https-port]

Defaults:
  web-port: 18080
  proxy-port: 7890
  https-port: 18443

The test starts package nginx, checks the welcome page, then checks HTTP and
CONNECT forward proxying with package bin/curl_static.
EOF
}

PACKAGE_DIR="${1:-}"
WEB_PORT="${2:-18080}"
PROXY_PORT="${3:-7890}"
HTTPS_PORT="${4:-18443}"

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
CURL_TIMEOUT_ARGS=(--connect-timeout 10 --max-time 30)
NGINX_CMD=("$NGINX_BIN")
CURL_CMD=("$CURL_BIN")
TEST_DIR="${PACKAGE_DIR}/test-runtime"
TEST_CONF="${TEST_DIR}/nginx-test.conf"
TEST_CERT="${TEST_DIR}/localhost.crt"
TEST_KEY="${TEST_DIR}/localhost.key"

[[ -x "$NGINX_BIN" ]] || die "missing nginx binary: ${NGINX_BIN}"
[[ -x "$CURL_BIN" ]] || die "missing curl_static binary: ${CURL_BIN}"

if [[ "$EXEEXT" == ".exe" ]]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      ;;
    *)
      command -v wine >/dev/null 2>&1 || die "wine is required to test Windows package on this host"
      NGINX_CMD=(wine "$NGINX_BIN")
      CURL_CMD=(wine "$CURL_BIN")
      ;;
  esac
fi

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/logs" "$TEST_DIR/run"

nginx_path() {
  local path="$1"

  if [[ "$EXEEXT" == ".exe" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  elif [[ "$EXEEXT" == ".exe" ]] && command -v winepath >/dev/null 2>&1; then
    winepath -w "$path" | tr '\\' '/'
  else
    printf '%s\n' "$path"
  fi
}

NGINX_PREFIX="$(nginx_path "${PACKAGE_DIR}/")"
NGINX_TEST_DIR="$(nginx_path "$TEST_DIR")"
NGINX_TEST_CONF="$(nginx_path "$TEST_CONF")"
NGINX_CONF_MIME="$(nginx_path "${PACKAGE_DIR}/conf/mime.types")"
NGINX_HTML_DIR="$(nginx_path "${PACKAGE_DIR}/html")"
NGINX_TEST_CERT="$(nginx_path "$TEST_CERT")"
NGINX_TEST_KEY="$(nginx_path "$TEST_KEY")"
NGINX_USER_DIRECTIVE=""

if [[ "$EXEEXT" != ".exe" && "$(id -u)" == "0" ]]; then
  touch /etc/passwd
  touch /etc/group
  grep -q '^root:' /etc/passwd || echo 'root:x:0:0:root:/root:/bin/sh' >>/etc/passwd
  grep -q '^root:' /etc/group || echo 'root:x:0:' >>/etc/group
  NGINX_USER_DIRECTIVE="user root;"
fi

cat >"$TEST_CERT" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUXqAXhu6F2KNZS5JRqpWlmQ+XIfAwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDYyODEzMjMwOVoXDTM2MDYy
NTEzMjMwOVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAohjbNPTAa1J7oXuRpf9MhlGAO2Y/XfVxDhEb1IbSnJcY
nZttVfXYZgZ4QHrOJaS3Yogs30gtMMFRG3VEGmL89u1xjZXeF5sfcPjUrmizqUbT
wQJw/MUpKYfVUiTWzpaMUAzlpAynYZX6kpGFQkXhDbV4RGi1CBHBM4BMeWTnSlfA
9/5jt3tjMfFEpfxVfTV3If16NCr0608Z/DS4X70GGuYqZhhSLTSFW8O+3TenSNuU
Yu9LUvyfgWil6viKvjVtKlY86BgSDM2OSI2ITCe6bmbYaZECx/44fKHMWH5Gu36s
RJ53x60QLBGULFJKmI+XAqXhBjLqoTF90YN8eJCgzwIDAQABo1MwUTAdBgNVHQ4E
FgQUx1HuZ0ZVpDcNUTx7IJYy9Lagey0wHwYDVR0jBBgwFoAUx1HuZ0ZVpDcNUTx7
IJYy9Lagey0wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAMUEp
qJZfoEpu5JAFre7OiNhiPd2pszB5xSE3H00BnZ/ZKPh6xCH4y3WtZ77tvaF4zdmo
vrIyaIDFxYytcJX8O51ZvbJrV+9i0FiQLvDag3p71eAP8T1cxa1sgw4Gw5/PuI8i
zjLdd7DACF3C4TLu3cA6b6jO1nDhNQqKTQeoL1YbDZCKwlDmJ05tmj7spImtnNZ8
KWS8TNPiASvnEuCz56GTkAbQnVZq4acdnJalxe6xdUypmlNcv1WjseNKBfG3vycg
FgO8wvKHV1bB9vf/uI+tyWa5CNX6aomZEzPDorxdjoRcNjxxJeqj+ZJSc1mZAQY1
vL2zCALxZDCRBudJSQ==
-----END CERTIFICATE-----
EOF

cat >"$TEST_KEY" <<'EOF'
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCiGNs09MBrUnuh
e5Gl/0yGUYA7Zj9d9XEOERvUhtKclxidm21V9dhmBnhAes4lpLdiiCzfSC0wwVEb
dUQaYvz27XGNld4Xmx9w+NSuaLOpRtPBAnD8xSkph9VSJNbOloxQDOWkDKdhlfqS
kYVCReENtXhEaLUIEcEzgEx5ZOdKV8D3/mO3e2Mx8USl/FV9NXch/Xo0KvTrTxn8
NLhfvQYa5ipmGFItNIVbw77dN6dI25Ri70tS/J+BaKXq+Iq+NW0qVjzoGBIMzY5I
jYhMJ7puZthpkQLH/jh8ocxYfka7fqxEnnfHrRAsEZQsUkqYj5cCpeEGMuqhMX3R
g3x4kKDPAgMBAAECggEAP+DgvcE39PM30j7SemKd4w7KJF5aWWooZ905JOsOo3Pt
2OpPz4DHCwnAqNRcWbxMInG8kS8t09lS36m6MVXSD3Mp/RxSveW9IbWFhsevCWXm
e9i88ve1jW7Ak5L97cKpP8CdXKU57vx+FvVu2NuV4WOipf7HXIs2oleMi4hGl2ZV
aXWAxCst8a0in6Vopbc+xDw4eItNvvRf3dZUbvlnDJhWqxu3npDpJmlvfOIdgMhC
v9GN6xt0RG2yKnkesWF8E4TmuBi0xNeqQSRKeImoarka4DmF/pe5pqUVLLRLPnVk
wxy6bZKrpTBCPKVuEtOzMaf5AJHDzfYI9JtNpU/e3QKBgQDe701pkPvACNwVjI2d
Fke5ow9XHK+pjokmq7bkmCe9lRK1QKk0XSuEAy+Ukvvyhef1JSzya4/DvPIFDJpA
SMTFyTrjsp22KjD+puMOBvxjjN1x0UBvKYG5f5XIpNP9Bfr+3l8gDC+0EeWix204
Cjk/1Y+fBkRi/kES0QkgQ+xamwKBgQC6I5WP/OrCKaHRFBHTBTMNWXjF/icpLqZu
XRVI1f4GvWP4qwh8uZz+Zhuzt0R6x9IoZZ5UHqXdhy0O8Wq77gbAUZHMT3+dIKIr
o12NVpQ3h5KNxSOgjGyGYR6DOcTdAh2BDoJBWjWbgLDIiqEYwjDVCfnWcidLOotc
57lxyyFL3QKBgEZ3J2Xl0N1LL52UFrL/dt5jfxbO12tlxU422pF40p7m/snRzWni
xT1t8F0q9H4c+0uOW52oiAGbuHgGGr+VALVvvLB6JcWNonzrbTti0+X3gYtXU+GP
IhTrEgIgr2z7tfFXgoPTtkRZn9cK6Cfde2kE7OecCIOt0A3Niu/q6EtfAoGBAIbe
E5cBfSNzwNBZx1RrdwMcKdrjfIJlT6e1gB+HFYjSnuXlHsAoSO03FKlRh6eiss4c
Wuy+TBXHxMkH+PrzyyZ7s7UigOdbZsVRmA45hij57SEVjuvb8yImqlIQgGhWCQSi
e5RYhXEHfI/BiloDEhi6IrDTg08Ju0J0j7Q4pwZtAoGBAKzCHmhyuVsSI9IdgfNd
yaxnAFogDVgkAbrkkAjN7g6IuNvfzwaxBHYeaPJ3+9d1+oROqkDzo8u5/R2I5ipU
OLh18SFIWhIgQzx7IA3nTOFvx0VYPbY6HRtO4qxCtYr4Gl34rKdh4I2E6DcitzUG
eqloKdpj8YxKfXL00uas85dZ
-----END PRIVATE KEY-----
EOF
chmod 600 "$TEST_KEY"

cat >"$TEST_CONF" <<EOF
${NGINX_USER_DIRECTIVE}
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

    access_log ${NGINX_TEST_DIR}/logs/access.log;
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
        listen 127.0.0.1:${HTTPS_PORT} ssl;
        server_name localhost;

        ssl_certificate ${NGINX_TEST_CERT};
        ssl_certificate_key ${NGINX_TEST_KEY};

        location / {
            return 200 "nginx local https ok\n";
        }
    }

    server {
        listen 127.0.0.1:${PROXY_PORT};
        server_name localhost;

        proxy_connect;
        proxy_connect_allow 443 563 ${HTTPS_PORT};
        proxy_connect_connect_timeout 10s;
        proxy_connect_read_timeout 20s;
        proxy_connect_send_timeout 20s;

        location / {
            proxy_pass http://\$http_host;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF

cleanup() {
  if [[ -f "${TEST_DIR}/run/nginx.pid" ]]; then
    "${NGINX_CMD[@]}" -p "$NGINX_PREFIX" -c "$NGINX_TEST_CONF" -s quit >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${NGINX_CMD[@]}" -p "$NGINX_PREFIX" -c "$NGINX_TEST_CONF" -e stderr -t
if [[ "$EXEEXT" == ".exe" ]]; then
  "${NGINX_CMD[@]}" -p "$NGINX_PREFIX" -c "$NGINX_TEST_CONF" -e stderr &
else
  "${NGINX_CMD[@]}" -p "$NGINX_PREFIX" -c "$NGINX_TEST_CONF" -e stderr
fi
sleep 1

echo "-- curl_static version"
"${CURL_CMD[@]}" -V

echo "-- testing nginx welcome page on http://127.0.0.1:${WEB_PORT}"
"${CURL_CMD[@]}" "${CURL_TIMEOUT_ARGS[@]}" -fsS "http://127.0.0.1:${WEB_PORT}/" | grep -q "Welcome to nginx"

echo "-- testing HTTP forward proxy on http://127.0.0.1:${PROXY_PORT}"
"${CURL_CMD[@]}" "${CURL_TIMEOUT_ARGS[@]}" -fsS -x "http://127.0.0.1:${PROXY_PORT}" "http://127.0.0.1:${WEB_PORT}/" | grep -q "Welcome to nginx"

echo "-- testing CONNECT forward proxy on http://127.0.0.1:${PROXY_PORT}"
"${CURL_CMD[@]}" "${CURL_TIMEOUT_ARGS[@]}" -k -fsS -x "http://127.0.0.1:${PROXY_PORT}" "https://127.0.0.1:${HTTPS_PORT}/" | grep -q "nginx local https ok"

echo "-- nginx package test passed"
