#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./packages/middleware/build_redis_mingw64_msys2.sh --redis-version=<ver> --out-dir=<dir> [--jobs=<n>]

Builds Redis for Windows under MSYS2/MINGW64 and stages the files needed by the
middleware MinGW package.
EOF
}

REDIS_VERSION="7.4.9"
OUT_DIR=""
JOBS="$(nproc 2>/dev/null || echo 4)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --redis-version=*) REDIS_VERSION="${1#*=}" ;;
    --redis-version) shift; [[ $# -gt 0 ]] || { echo "--redis-version requires a value" >&2; exit 1; }; REDIS_VERSION="$1" ;;
    --out-dir=*) OUT_DIR="${1#*=}" ;;
    --out-dir) shift; [[ $# -gt 0 ]] || { echo "--out-dir requires a value" >&2; exit 1; }; OUT_DIR="$1" ;;
    --jobs=*) JOBS="${1#*=}" ;;
    --jobs) shift; [[ $# -gt 0 ]] || { echo "--jobs requires a value" >&2; exit 1; }; JOBS="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

[[ -n "$OUT_DIR" ]] || { echo "--out-dir is required" >&2; exit 1; }

WORK_DIR="${PWD}/redis-mingw64-work"
ARCHIVE_PATH="${WORK_DIR}/redis-${REDIS_VERSION}.tar.gz"
SOURCE_DIR="${WORK_DIR}/redis-${REDIS_VERSION}"

rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR/bin" "$OUT_DIR/conf"

curl -L --fail --retry 3 \
  -o "$ARCHIVE_PATH" \
  "https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz"

# Redis' POSIX build expects dlinfo declarations that MSYS2 hides behind
# __GNU_VISIBLE. The redis-windows MSYS2 build applies the same compatibility
# tweak before compiling.
if grep -q '__GNU_VISIBLE' /usr/include/dlfcn.h; then
  sed -i 's/__GNU_VISIBLE/1/g' /usr/include/dlfcn.h
fi

tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR"

export CC="${CC:-gcc}"
export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

echo "MSYSTEM=${MSYSTEM:-}"
echo "cc: $(command -v "$CC")"
"$CC" -dumpmachine
"$CC" --version | head -n 1
echo "pkg-config: $(command -v "$PKG_CONFIG")"

redis_make_flags=(
  BUILD_TLS=yes
  MALLOC=libc
  OPTIMIZATION=-O0
  CFLAGS=-Wno-char-subscripts
  LDFLAGS=-fno-lto
  REDIS_CFLAGS=-fno-lto
  REDIS_LDFLAGS=-fno-lto
)

(
  cd "$SOURCE_DIR/src"
  make -j "$JOBS" \
    "${redis_make_flags[@]}" \
    redis-server redis-cli redis-benchmark
)

install -m 755 \
  "$SOURCE_DIR/src/redis-server.exe" \
  "$SOURCE_DIR/src/redis-cli.exe" \
  "$SOURCE_DIR/src/redis-benchmark.exe" \
  "$OUT_DIR/bin/"

install -m 644 \
  "$SOURCE_DIR/redis.conf" \
  "$SOURCE_DIR/sentinel.conf" \
  "$OUT_DIR/conf/"

sed -i 's,pidfile /var/run,pidfile .,' "$OUT_DIR/conf/redis.conf"

copy_runtime_deps() {
  local binary="$1"

  ldd "$binary" \
    | awk '
        $2 == "=>" && $3 ~ /^\/usr\/bin\// { print $3 }
        $1 ~ /^\/usr\/bin\// { print $1 }
      '
}

{
  printf '%s\n' /usr/bin/msys-2.0.dll
  copy_runtime_deps "$OUT_DIR/bin/redis-server.exe"
  copy_runtime_deps "$OUT_DIR/bin/redis-cli.exe"
  copy_runtime_deps "$OUT_DIR/bin/redis-benchmark.exe"
} | LC_ALL=C sort -u | while IFS= read -r dll_path; do
  [[ -f "$dll_path" ]] || continue
  install -m 755 "$dll_path" "$OUT_DIR/bin/"
done

"$OUT_DIR/bin/redis-server.exe" --version | grep -F "$REDIS_VERSION"
