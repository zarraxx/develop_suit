#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/container_build.sh --arch=<arch> [options]

Options:
  --arch=<arch>       Target arch: x86_64, aarch64, riscv64, loongarch64
  --jobs=<n>          Parallel build jobs (default: nproc)
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  Build dir (default: /work/build)
  --out-dir=<path>    DESTDIR output dir (default: /work/out/<arch>)
  --deps-dir=<path>   Copied target image deps dir (default: /work/deps/<arch>)
  -h, --help          Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

restore_host_access() {
  chmod -R a+rwX "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" 2>/dev/null || true
}

download_archive() {
  url="$1"
  archive="$2"

  mkdir -p "$CACHE_DIR"
  if [ ! -s "${CACHE_DIR}/${archive}" ]; then
    rm -f "${CACHE_DIR}/${archive}" "${CACHE_DIR}/${archive}.tmp"
    echo "-- downloading ${archive}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive}.tmp" "$url"
    mv "${CACHE_DIR}/${archive}.tmp" "${CACHE_DIR}/${archive}"
  fi
}

normalize_arch() {
  case "$1" in
    x86_64|amd64|x64|x86)
      echo "x86_64"
      ;;
    aarch64|arm64)
      echo "aarch64"
      ;;
    riscv64|riscv64gc)
      echo "riscv64"
      ;;
    loongarch64|loong64)
      echo "loongarch64"
      ;;
    *)
      die "unsupported arch: $1"
      ;;
  esac
}

triple_for_arch() {
  case "$1" in
    x86_64)
      echo "x86_64-unknown-linux-gnu"
      ;;
    aarch64)
      echo "aarch64-unknown-linux-gnu"
      ;;
    riscv64)
      echo "riscv64-unknown-linux-gnu"
      ;;
    loongarch64)
      echo "loongarch64-unknown-linux-gnu"
      ;;
    *)
      die "no triple mapping for arch: $1"
      ;;
  esac
}

ARCH=""
JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build"
OUT_DIR=""
DEPS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --arch=*)
      ARCH="${1#*=}"
      ;;
    --arch)
      shift
      [ $# -gt 0 ] || die "--arch requires a value"
      ARCH="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [ $# -gt 0 ] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --cache-dir=*)
      CACHE_DIR="${1#*=}"
      ;;
    --cache-dir)
      shift
      [ $# -gt 0 ] || die "--cache-dir requires a value"
      CACHE_DIR="$1"
      ;;
    --build-dir=*)
      BUILD_DIR="${1#*=}"
      ;;
    --build-dir)
      shift
      [ $# -gt 0 ] || die "--build-dir requires a value"
      BUILD_DIR="$1"
      ;;
    --out-dir=*)
      OUT_DIR="${1#*=}"
      ;;
    --out-dir)
      shift
      [ $# -gt 0 ] || die "--out-dir requires a value"
      OUT_DIR="$1"
      ;;
    --deps-dir=*)
      DEPS_DIR="${1#*=}"
      ;;
    --deps-dir)
      shift
      [ $# -gt 0 ] || die "--deps-dir requires a value"
      DEPS_DIR="$1"
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

[ -n "$ARCH" ] || die "--arch is required"
ARCH="$(normalize_arch "$ARCH")"
TARGET_TRIPLE="$(triple_for_arch "$ARCH")"
OUT_DIR="${OUT_DIR:-/work/out/${ARCH}}"
DEPS_DIR="${DEPS_DIR:-/work/deps/${ARCH}}"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"
trap restore_host_access EXIT INT TERM

[ -d "${DEPS_DIR}/usr" ] || die "target deps /usr not found: ${DEPS_DIR}/usr"

echo "-- stage_tools container build"
echo "-- arch: ${ARCH}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- out dir: ${OUT_DIR}"
echo "-- deps dir: ${DEPS_DIR}"

download_archive \
  "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2" \
  "pcre2-10.47.tar.bz2"

download_archive \
  "https://www.kernel.org/pub/software/scm/git/git-2.54.0.tar.gz" \
  "git-2.54.0.tar.gz"

download_archive \
  "https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz" \
  "bash-5.3.tar.gz"

download_archive \
  "https://github.com/mesonbuild/meson/releases/download/1.11.1/meson-1.11.1.tar.gz" \
  "meson-1.11.1.tar.gz"

/work/mount_root/build_cmake.sh \
  --arch="$ARCH" \
  --jobs="$JOBS" \
  --cache-dir="$CACHE_DIR" \
  --build-dir="${BUILD_DIR}/native-tools" \
  --out-dir="$OUT_DIR" \
  --deps-dir="$DEPS_DIR"

CMAKE_BIN="${BUILD_DIR}/native-tools/stage0/cmake3/bin/cmake"
[ -x "$CMAKE_BIN" ] || die "stage0 cmake3 was not installed: $CMAKE_BIN"

CMAKE_BUILD_DIR="${BUILD_DIR}/cmake-external/${ARCH}"
rm -rf "$CMAKE_BUILD_DIR"
mkdir -p "$CMAKE_BUILD_DIR"

"$CMAKE_BIN" \
  -S /work/mount_root \
  -B "$CMAKE_BUILD_DIR" \
  -G "Unix Makefiles" \
  -DSTAGE_TOOLS_ARCH="$ARCH" \
  -DSTAGE_TOOLS_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DSTAGE_TOOLS_CACHE_DIR="$CACHE_DIR" \
  -DSTAGE_TOOLS_OUT_DIR="$OUT_DIR" \
  -DSTAGE_TOOLS_DEPS_DIR="$DEPS_DIR" \
  -DSTAGE_TOOLS_JOBS="$JOBS"

"$CMAKE_BIN" --build "$CMAKE_BUILD_DIR" --parallel "$JOBS"

echo "-- stage_tools container build ok: ${OUT_DIR}"
