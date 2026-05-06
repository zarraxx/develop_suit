#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/build_file_package.sh --arch=<arch> [options]

Options:
  --arch=<arch>       Target arch: x86_64, aarch64, riscv64, loongarch64
  --jobs=<n>          Parallel build jobs (default: nproc)
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --out-dir=<path>    DESTDIR output dir (default: /work/out/<arch>)
  --deps-dir=<path>   Copied target image deps dir (default: /work/deps/<arch>)
  -h, --help          Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
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

extract_file_source() {
  dest_dir="$1"

  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  tar -C "$dest_dir" --strip-components=1 -xzf "${CACHE_DIR}/${ARCHIVE_NAME}"
}

ARCH=""
JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
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

TOOLCHAIN_ROOT="/opt/llvm-18.1.8"
SYSROOT="/opt/sysroot/${TARGET_TRIPLE}"
CC="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc"
LD="${TOOLCHAIN_ROOT}/bin/ld.lld"
AR="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-ar"
RANLIB="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-ranlib"
STRIP="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-strip"
TARGET_CFLAGS="--sysroot=${SYSROOT} -O2 -I${OUT_DIR}/usr/include -I${DEPS_DIR}/usr/include"
TARGET_LDFLAGS="--sysroot=${SYSROOT} -L${OUT_DIR}/usr/lib -L${OUT_DIR}/usr/lib64 -L${SYSROOT}/usr/lib -L${SYSROOT}/lib -L${DEPS_DIR}/usr/lib -L${DEPS_DIR}/usr/lib64 -Wl,-rpath-link,${OUT_DIR}/usr/lib -Wl,-rpath-link,${OUT_DIR}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${DEPS_DIR}/usr/lib -Wl,-rpath-link,${DEPS_DIR}/usr/lib64"
HOST_TRIPLE="x86_64-unknown-linux-gnu"
HOST_SYSROOT="/opt/sysroot/${HOST_TRIPLE}"
HOST_CC="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-clang-gcc"
HOST_LD="${TOOLCHAIN_ROOT}/bin/ld.lld"
HOST_AR="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-ar"
HOST_RANLIB="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-ranlib"
HOST_STRIP="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-strip"

FILE_VERSION="5.47"
ARCHIVE_NAME="file-${FILE_VERSION}.tar.gz"
BUILD_ROOT="/work/build/${ARCH}/file"
SRC_ROOT="${BUILD_ROOT}/src"
HOST_BUILD_ROOT="/work/build/host/file"
HOST_SRC_ROOT="${HOST_BUILD_ROOT}/src"
HOST_FILE_COMPILE="${HOST_SRC_ROOT}/src/file"
HOST_MAGIC_FILE="${HOST_SRC_ROOT}/magic/magic.mgc"

require_command curl
require_command make
require_command tar

[ -x "$CC" ] || die "target compiler not found: $CC"
[ -x "$LD" ] || die "target linker not found: $LD"
[ -x "$AR" ] || die "target ar not found: $AR"
[ -x "$RANLIB" ] || die "target ranlib not found: $RANLIB"
[ -d "$SYSROOT" ] || die "target sysroot not found: $SYSROOT"
[ -d "${DEPS_DIR}/usr" ] || die "target deps /usr not found: ${DEPS_DIR}/usr"

PATH="${TOOLCHAIN_ROOT}/bin:${PATH}"
export PATH

mkdir -p "$CACHE_DIR" "$OUT_DIR" "$BUILD_ROOT"

if [ ! -f "${CACHE_DIR}/${ARCHIVE_NAME}" ]; then
  echo "-- downloading ${ARCHIVE_NAME}"
  curl -L --fail --retry 3 \
    -o "${CACHE_DIR}/${ARCHIVE_NAME}.tmp" \
    "ftp://ftp.astron.com/pub/file/${ARCHIVE_NAME}"
  mv "${CACHE_DIR}/${ARCHIVE_NAME}.tmp" "${CACHE_DIR}/${ARCHIVE_NAME}"
fi

if [ "$ARCH" != "x86_64" ] && [ ! -x "$HOST_FILE_COMPILE" ]; then
  [ -x "$HOST_CC" ] || die "host compiler not found: $HOST_CC"
  [ -x "$HOST_LD" ] || die "host linker not found: $HOST_LD"
  [ -x "$HOST_AR" ] || die "host ar not found: $HOST_AR"
  [ -x "$HOST_RANLIB" ] || die "host ranlib not found: $HOST_RANLIB"
  [ -d "$HOST_SYSROOT" ] || die "host sysroot not found: $HOST_SYSROOT"

  echo "-- building host file ${FILE_VERSION} for magic compiler"
  mkdir -p "$HOST_BUILD_ROOT"
  extract_file_source "$HOST_SRC_ROOT"

  (
    cd "$HOST_SRC_ROOT"
    CC="$HOST_CC" \
    LD="$HOST_LD" \
    AR="$HOST_AR" \
    RANLIB="$HOST_RANLIB" \
    STRIP="$HOST_STRIP" \
    CFLAGS="--sysroot=${HOST_SYSROOT} -O2" \
    LDFLAGS="--sysroot=${HOST_SYSROOT}" \
    ./configure \
      --build="${HOST_TRIPLE}" \
      --host="${HOST_TRIPLE}" \
      --prefix=/usr \
      --disable-silent-rules

    make -j"${JOBS}"
  )
fi

if [ "$ARCH" != "x86_64" ]; then
  [ -x "$HOST_FILE_COMPILE" ] || die "host file compiler was not built: $HOST_FILE_COMPILE"
  FILE_COMPILE_ARG="FILE_COMPILE=${HOST_FILE_COMPILE}"
else
  FILE_COMPILE_ARG=""
fi

extract_file_source "$SRC_ROOT"

cd "$SRC_ROOT"

echo "-- configuring file ${FILE_VERSION} for ${TARGET_TRIPLE}"
CC="$CC" \
LD="$LD" \
AR="$AR" \
RANLIB="$RANLIB" \
STRIP="$STRIP" \
CFLAGS="$TARGET_CFLAGS" \
LDFLAGS="$TARGET_LDFLAGS" \
PKG_CONFIG_SYSROOT_DIR="$DEPS_DIR" \
PKG_CONFIG_LIBDIR="${OUT_DIR}/usr/lib/pkgconfig:${OUT_DIR}/usr/lib64/pkgconfig:${DEPS_DIR}/usr/lib/pkgconfig:${DEPS_DIR}/usr/lib64/pkgconfig:${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig" \
./configure \
  --build=x86_64-unknown-linux-gnu \
  --host="${TARGET_TRIPLE}" \
  --prefix=/usr \
  --disable-silent-rules \
  --disable-zlib \
  --disable-bzlib \
  --disable-xzlib \
  --disable-zstdlib \
  --disable-lzlib \
  --disable-lrziplib \
  --disable-libseccomp

echo "-- building file ${FILE_VERSION}"
if [ -n "$FILE_COMPILE_ARG" ]; then
  make -j"${JOBS}" "$FILE_COMPILE_ARG"
else
  make -j"${JOBS}"
fi

echo "-- installing file ${FILE_VERSION} to ${OUT_DIR}"
if [ -n "$FILE_COMPILE_ARG" ]; then
  make install DESTDIR="${OUT_DIR}" "$FILE_COMPILE_ARG"
else
  make install DESTDIR="${OUT_DIR}"
fi

if [ "$ARCH" = "x86_64" ]; then
  LD_LIBRARY_PATH="${OUT_DIR}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${OUT_DIR}/usr/bin/file" --version
else
  "$HOST_FILE_COMPILE" -m "$HOST_MAGIC_FILE" "${OUT_DIR}/usr/bin/file"
fi
echo "-- file package build ok: ${OUT_DIR}"
