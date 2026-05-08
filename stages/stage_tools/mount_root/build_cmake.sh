#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/build_cmake.sh --arch=<arch> [options]

Options:
  --arch=<arch>       Target arch: x86_64, aarch64, riscv64, loongarch64
  --jobs=<n>          Parallel build jobs (default: nproc)
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  CMake build dir (default: /work/build/native-tools)
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

download_archive() {
  url="$1"
  archive="$2"

  mkdir -p "$CACHE_DIR"
  if [ ! -f "${CACHE_DIR}/${archive}" ]; then
    echo "-- downloading ${archive}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive}.tmp" "$url"
    mv "${CACHE_DIR}/${archive}.tmp" "${CACHE_DIR}/${archive}"
  fi
}

extract_archive() {
  archive="$1"
  dest_dir="$2"

  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  case "$archive" in
    *.tar.gz|*.tgz)
      tar -C "$dest_dir" --strip-components=1 -xzf "${CACHE_DIR}/${archive}"
      ;;
    *.tar.xz)
      tar -C "$dest_dir" --strip-components=1 -xJf "${CACHE_DIR}/${archive}"
      ;;
    *.tar.bz2)
      tar -C "$dest_dir" --strip-components=1 -xjf "${CACHE_DIR}/${archive}"
      ;;
    *)
      die "unsupported archive format: $archive"
      ;;
  esac
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

build_stage0_cmake3() {
  version="3.27.9"
  archive="cmake-${version}.tar.gz"
  url="https://cmake.org/files/v3.27/${archive}"
  src_dir="${BUILD_DIR}/stage0/cmake-${version}/src"
  build_dir="${BUILD_DIR}/stage0/cmake-${version}/build"
  install_dir="${BUILD_DIR}/stage0/cmake3"

  if [ -x "${install_dir}/bin/cmake" ]; then
    echo "-- stage0 cmake3 already installed: ${install_dir}/bin/cmake"
    "${install_dir}/bin/cmake" --version
    return 0
  fi

  download_archive "$url" "$archive"
  extract_archive "$archive" "$src_dir"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  echo "-- bootstrapping native stage0 cmake ${version}"
  (
    cd "$build_dir"
    CC="$HOST_CC" \
    CXX="$HOST_CXX" \
    LD="$HOST_LD" \
    AR="$HOST_AR" \
    RANLIB="$HOST_RANLIB" \
    CFLAGS="--sysroot=${HOST_SYSROOT} -O2" \
    CXXFLAGS="--sysroot=${HOST_SYSROOT} -O2" \
    LDFLAGS="--sysroot=${HOST_SYSROOT}" \
      "${src_dir}/bootstrap" \
        --prefix="$install_dir" \
        --parallel="${JOBS}" \
        -- \
        -DCMAKE_USE_OPENSSL=OFF \
        -DBUILD_TESTING=OFF \
        -DCMake_TEST_NO_NETWORK=ON

    make -j"${JOBS}"
    make install
  )

  "${install_dir}/bin/cmake" --version
}

write_target_toolchain_file() {
  toolchain_file="$1"

  mkdir -p "$(dirname "$toolchain_file")"
  cat >"$toolchain_file" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${ARCH})
set(CMAKE_SYSROOT ${TARGET_SYSROOT})
set(CMAKE_C_COMPILER ${TARGET_CC})
set(CMAKE_CXX_COMPILER ${TARGET_CXX})
set(CMAKE_AR ${TARGET_AR})
set(CMAKE_RANLIB ${TARGET_RANLIB})
set(CMAKE_STRIP ${TARGET_STRIP})
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH
  ${STAGE_TOOLS_OUT_DIR}
  ${STAGE_TOOLS_DEPS_DIR}
  ${TARGET_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_PREFIX_PATH
  ${STAGE_TOOLS_OUT_DIR}/usr
  ${STAGE_TOOLS_DEPS_DIR}/usr
  ${TARGET_SYSROOT}/usr)
set(CMAKE_C_FLAGS_INIT "--sysroot=${TARGET_SYSROOT} -O2")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=${TARGET_SYSROOT} -O2")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--sysroot=${TARGET_SYSROOT} -pthread")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "\${CMAKE_EXE_LINKER_FLAGS_INIT}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "\${CMAKE_EXE_LINKER_FLAGS_INIT}")
EOF
}

build_target_cmake() {
  version="$1"
  url="$2"
  install_prefix="$3"
  archive="cmake-${version}.tar.gz"
  src_dir="${BUILD_DIR}/target/${ARCH}/cmake-${version}/src"
  build_dir="${BUILD_DIR}/target/${ARCH}/cmake-${version}/build"
  marker="${build_dir}/.stage-tools-installed"

  download_archive "$url" "$archive"

  if [ ! -f "${src_dir}/CMakeLists.txt" ]; then
    extract_archive "$archive" "$src_dir"
  fi

  mkdir -p "$build_dir"

  echo "-- configuring target cmake ${version} for ${TARGET_TRIPLE}"
  "$STAGE0_CMAKE" \
    -S "$src_dir" \
    -B "$build_dir" \
    -G "Unix Makefiles" \
    -DCMAKE_MAKE_PROGRAM="$HOST_MAKE" \
    -DCMAKE_TOOLCHAIN_FILE="$TARGET_TOOLCHAIN_FILE" \
    -DCMAKE_INSTALL_PREFIX="$install_prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="--sysroot=${TARGET_SYSROOT} -pthread" \
    -DCMAKE_SHARED_LINKER_FLAGS="--sysroot=${TARGET_SYSROOT} -pthread" \
    -DCMAKE_MODULE_LINKER_FLAGS="--sysroot=${TARGET_SYSROOT} -pthread" \
    -DCMAKE_USE_OPENSSL=OFF \
    -DLIBMD_FOUND=FALSE \
    -DHAVE__CTIME64_S=FALSE \
    -DHAVE__FSEEKI64=FALSE \
    -DHAVE__GMTIME64_S=FALSE \
    -DHAVE__LOCALTIME64_S=FALSE \
    -DHAVE__MKGMTIME64=FALSE \
    -DHAVE_STRNCPY_S=FALSE \
    -DHAVE_LIBIDN2=FALSE \
    -DHAVE_LIBSOCKET=FALSE \
    -DHAVE_CLOSEFROM=FALSE \
    -DHAVE_CLOSE_RANGE=FALSE \
    -DBUILD_TESTING=OFF \
    -DCMake_TEST_NO_NETWORK=ON

  echo "-- building target cmake ${version}"
  "$STAGE0_CMAKE" --build "$build_dir" --parallel "$JOBS"

  echo "-- installing target cmake ${version} to ${STAGE_TOOLS_OUT_DIR}${install_prefix}"
  DESTDIR="$STAGE_TOOLS_OUT_DIR" "$STAGE0_CMAKE" --install "$build_dir"
  echo "installed ${version} for ${TARGET_TRIPLE}" >"$marker"
}

ARCH=""
JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build/native-tools"
STAGE_TOOLS_OUT_DIR=""
STAGE_TOOLS_DEPS_DIR=""

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
      STAGE_TOOLS_OUT_DIR="${1#*=}"
      ;;
    --out-dir)
      shift
      [ $# -gt 0 ] || die "--out-dir requires a value"
      STAGE_TOOLS_OUT_DIR="$1"
      ;;
    --deps-dir=*)
      STAGE_TOOLS_DEPS_DIR="${1#*=}"
      ;;
    --deps-dir)
      shift
      [ $# -gt 0 ] || die "--deps-dir requires a value"
      STAGE_TOOLS_DEPS_DIR="$1"
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
STAGE_TOOLS_OUT_DIR="${STAGE_TOOLS_OUT_DIR:-/work/out/${ARCH}}"
STAGE_TOOLS_DEPS_DIR="${STAGE_TOOLS_DEPS_DIR:-/work/deps/${ARCH}}"

TOOLCHAIN_ROOT="/opt/llvm-18.1.8"
HOST_TRIPLE="x86_64-unknown-linux-gnu"
HOST_SYSROOT="/opt/sysroot/${HOST_TRIPLE}"
HOST_CC="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-clang-gcc"
HOST_CXX="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-clang-g++"
HOST_LD="${TOOLCHAIN_ROOT}/bin/ld.lld"
HOST_AR="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-ar"
HOST_RANLIB="${TOOLCHAIN_ROOT}/bin/${HOST_TRIPLE}-ranlib"

TARGET_SYSROOT="/opt/sysroot/${TARGET_TRIPLE}"
TARGET_CC="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc"
TARGET_CXX="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-clang-g++"
TARGET_AR="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-ar"
TARGET_RANLIB="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-ranlib"
TARGET_STRIP="${TOOLCHAIN_ROOT}/bin/${TARGET_TRIPLE}-strip"

require_command curl
require_command make
require_command tar
HOST_MAKE="$(command -v make)"

[ -x "$HOST_CC" ] || die "host compiler not found: $HOST_CC"
[ -x "$HOST_CXX" ] || die "host c++ compiler not found: $HOST_CXX"
[ -x "$HOST_LD" ] || die "host linker not found: $HOST_LD"
[ -d "$HOST_SYSROOT" ] || die "host sysroot not found: $HOST_SYSROOT"
[ -x "$TARGET_CC" ] || die "target compiler not found: $TARGET_CC"
[ -x "$TARGET_CXX" ] || die "target c++ compiler not found: $TARGET_CXX"
[ -x "$TARGET_AR" ] || die "target ar not found: $TARGET_AR"
[ -x "$TARGET_RANLIB" ] || die "target ranlib not found: $TARGET_RANLIB"
[ -d "$TARGET_SYSROOT" ] || die "target sysroot not found: $TARGET_SYSROOT"
[ -d "${STAGE_TOOLS_DEPS_DIR}/usr" ] || die "target deps /usr not found: ${STAGE_TOOLS_DEPS_DIR}/usr"

PATH="${TOOLCHAIN_ROOT}/bin:${PATH}"
export PATH

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$STAGE_TOOLS_OUT_DIR"

build_stage0_cmake3

STAGE0_CMAKE="${BUILD_DIR}/stage0/cmake3/bin/cmake"
TARGET_TOOLCHAIN_FILE="${BUILD_DIR}/toolchains/${TARGET_TRIPLE}.cmake"
[ -x "$STAGE0_CMAKE" ] || die "stage0 cmake3 was not built: $STAGE0_CMAKE"

write_target_toolchain_file "$TARGET_TOOLCHAIN_FILE"

build_target_cmake \
  "3.27.9" \
  "https://cmake.org/files/v3.27/cmake-3.27.9.tar.gz" \
  "/opt/cmake3"

build_target_cmake \
  "4.3.2" \
  "https://github.com/Kitware/CMake/releases/download/v4.3.2/cmake-4.3.2.tar.gz" \
  "/opt/cmake4"

echo "-- stage0 cmake driver: ${STAGE0_CMAKE}"
