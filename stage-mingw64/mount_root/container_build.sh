#!/bin/sh

set -eu

TARGET_TRIPLE="x86_64-w64-windows-gnu"
MINGW_ARCHIVE_NAME="compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz"
MINGW_ARCHIVE_URL="https://github.com/zarraxx/package_builder/releases/download/compiler-mingw32-gcc-15.2.0/compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz"

usage() {
  cat <<'EOF'
Usage:
  /work/mount_root/container_build.sh --arch=x86_64 [options]

Options:
  --arch=<arch>       Host arch for produced Linux tools (initially x86_64)
  --jobs=<n>          Parallel build jobs (reserved for runtime builds)
  --cache-dir=<path>  Source archive cache dir (default: /work/cache)
  --build-dir=<path>  Build dir (default: /work/build)
  --out-dir=<path>    DESTDIR output dir (default: /work/out/<arch>)
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
    *)
      die "stage-mingw64 initially supports only x86_64 host output: $1"
      ;;
  esac
}

find_mingw_root() {
  extract_dir="$1"
  found_gcc=""

  found_gcc="$(find "$extract_dir" -type f -path "*/bin/*-gcc" -perm -111 | head -n 1 || true)"
  if [ -n "$found_gcc" ]; then
    dirname "$(dirname "$found_gcc")"
    return 0
  fi

  return 1
}

detect_package_triple() {
  install_root="$1"
  found_gcc=""
  tool_name=""

  found_gcc="$(find "$install_root/bin" -maxdepth 1 -type f -name '*-gcc' -perm -111 | head -n 1 || true)"
  [ -n "$found_gcc" ] || return 1

  tool_name="$(basename "$found_gcc")"
  printf '%s\n' "${tool_name%-gcc}"
}

rename_dir_if_exists() {
  old_path="$1"
  new_path="$2"

  if [ -d "$old_path" ] && [ "$old_path" != "$new_path" ]; then
    [ ! -e "$new_path" ] || die "cannot rename ${old_path}; destination exists: ${new_path}"
    mv "$old_path" "$new_path"
  fi
}

rename_prefixed_tools() {
  bin_dir="$1"
  old_triple="$2"
  new_triple="$3"
  tool=""
  tool_base=""
  new_tool=""

  [ "$old_triple" != "$new_triple" ] || return 0

  for tool in "${bin_dir}/${old_triple}"-*; do
    [ -e "$tool" ] || continue
    tool_base="$(basename "$tool")"
    new_tool="${bin_dir}/${new_triple}${tool_base#${old_triple}}"
    [ ! -e "$new_tool" ] || die "cannot rename ${tool}; destination exists: ${new_tool}"
    mv "$tool" "$new_tool"
  done
}

normalize_installed_triple() {
  install_root="$1"
  package_triple="$2"

  rename_prefixed_tools "${install_root}/bin" "$package_triple" "$TARGET_TRIPLE"
  rename_dir_if_exists "${install_root}/${package_triple}" "${install_root}/${TARGET_TRIPLE}"
  rename_dir_if_exists "${install_root}/lib/gcc/${package_triple}" "${install_root}/lib/gcc/${TARGET_TRIPLE}"
  rename_dir_if_exists "${install_root}/libexec/gcc/${package_triple}" "${install_root}/libexec/gcc/${TARGET_TRIPLE}"
  rename_dir_if_exists \
    "${install_root}/${TARGET_TRIPLE}/sysroot/usr/${package_triple}" \
    "${install_root}/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}"
}

rewrite_known_text_refs() {
  install_root="$1"
  package_triple="$2"
  text_file=""

  [ "$package_triple" != "$TARGET_TRIPLE" ] || return 0

  find "$install_root" -type f \( \
      -name '*.cmake' \
      -o -name '*.conf' \
      -o -name '*.h' \
      -o -name '*.py' \
      -o -name '*.state' \
      -o -name 'mkheaders' \
      -o -path '*/ldscripts/*' \
    \) | while IFS= read -r text_file; do
    sed -i \
      -e "s|${package_triple}-gcc${GCC_VERSION}|${TARGET_TRIPLE}|g" \
      -e "s|${package_triple}|${TARGET_TRIPLE}|g" \
      "$text_file"
  done
}

write_clang_cfg() {
  cfg_path="$1"
  add_cxx="$2"

  cat >"$cfg_path" <<EOF
# Default Windows GNU cross configuration for ${TARGET_TRIPLE}.
--target=${TARGET_TRIPLE}
--sysroot=<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/sysroot
-B
<CFGDIR>/../../${TARGET_TRIPLE}/bin
-B
<CFGDIR>/../../${TARGET_TRIPLE}/lib/gcc/${TARGET_TRIPLE}/${GCC_VERSION}
EOF

  if [ "$add_cxx" = 1 ]; then
    cat >>"$cfg_path" <<EOF
-isystem
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}
-isystem
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}/${TARGET_TRIPLE}
-isystem
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}/backward
EOF
  fi

  cat >>"$cfg_path" <<EOF
-isystem
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/include
-L
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/lib
-L
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/sysroot/lib
-L
<CFGDIR>/../../${TARGET_TRIPLE}/${TARGET_TRIPLE}/lib
-L
<CFGDIR>/../../${TARGET_TRIPLE}/lib/gcc/${TARGET_TRIPLE}/${GCC_VERSION}
--rtlib=libgcc
EOF

  if [ "$add_cxx" = 1 ]; then
    printf '%s\n' '-stdlib=libstdc++' >>"$cfg_path"
  fi
}

write_cmake_toolchain() {
  toolchain_path="$1"

  cat >"$toolchain_path" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER /opt/llvm-18.1.8/bin/${TARGET_TRIPLE}-clang-gcc)
set(CMAKE_CXX_COMPILER /opt/llvm-18.1.8/bin/${TARGET_TRIPLE}-clang-g++)

set(CMAKE_FIND_ROOT_PATH /opt/${TARGET_TRIPLE}/${TARGET_TRIPLE}/sysroot)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

ARCH=""
JOBS="$(nproc 2>/dev/null || echo 1)"
CACHE_DIR="/work/cache"
BUILD_DIR="/work/build"
OUT_DIR=""

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
OUT_DIR="${OUT_DIR:-/work/out/${ARCH}}"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"
trap restore_host_access EXIT INT TERM

echo "-- stage-mingw64 container build"
echo "-- host arch: ${ARCH}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- out dir: ${OUT_DIR}"

download_archive "$MINGW_ARCHIVE_URL" "$MINGW_ARCHIVE_NAME"

EXTRACT_DIR="${BUILD_DIR}/${ARCH}/mingw-extract"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xf "${CACHE_DIR}/${MINGW_ARCHIVE_NAME}" -C "$EXTRACT_DIR"

MINGW_ROOT="$(find_mingw_root "$EXTRACT_DIR")" || die "could not find MinGW GCC root in archive"

rm -rf "$OUT_DIR"
mkdir -p \
  "${OUT_DIR}/opt" \
  "${OUT_DIR}/opt/llvm-18.1.8/bin"

cp -a "$MINGW_ROOT" "${OUT_DIR}/opt/${TARGET_TRIPLE}"

MINGW_INSTALL="${OUT_DIR}/opt/${TARGET_TRIPLE}"
PACKAGE_TARGET_TRIPLE="$(detect_package_triple "$MINGW_INSTALL")" || die "could not detect package GCC target triple under ${MINGW_INSTALL}"
normalize_installed_triple "$MINGW_INSTALL" "$PACKAGE_TARGET_TRIPLE"

GCC_LIB_ROOT="${MINGW_INSTALL}/lib/gcc/${TARGET_TRIPLE}"
[ -d "$GCC_LIB_ROOT" ] || die "missing GCC runtime lib root: ${GCC_LIB_ROOT}"
GCC_VERSION="$(find "$GCC_LIB_ROOT" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | sort | tail -n 1)"
[ -n "$GCC_VERSION" ] || die "could not detect GCC runtime version under ${GCC_LIB_ROOT}"

rename_dir_if_exists \
  "${MINGW_INSTALL}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}/${PACKAGE_TARGET_TRIPLE}" \
  "${MINGW_INSTALL}/${TARGET_TRIPLE}/include/c++/${GCC_VERSION}/${TARGET_TRIPLE}"
rewrite_known_text_refs "$MINGW_INSTALL" "$PACKAGE_TARGET_TRIPLE"

[ -x "${MINGW_INSTALL}/bin/${TARGET_TRIPLE}-gcc" ] || die "missing MinGW gcc: ${MINGW_INSTALL}/bin/${TARGET_TRIPLE}-gcc"
[ -d "${MINGW_INSTALL}/${TARGET_TRIPLE}/include" ] || die "missing target include dir: ${MINGW_INSTALL}/${TARGET_TRIPLE}/include"
[ -d "${MINGW_INSTALL}/${TARGET_TRIPLE}/lib" ] || die "missing target lib dir: ${MINGW_INSTALL}/${TARGET_TRIPLE}/lib"
[ -d "${MINGW_INSTALL}/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/include" ] || die "missing target sysroot include dir"
[ -d "${MINGW_INSTALL}/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/lib" ] || die "missing target sysroot lib dir"

LLVM_BIN="${OUT_DIR}/opt/llvm-18.1.8/bin"
ln -sfn clang "${LLVM_BIN}/${TARGET_TRIPLE}-clang-gcc"
ln -sfn clang++ "${LLVM_BIN}/${TARGET_TRIPLE}-clang-g++"
write_clang_cfg "${LLVM_BIN}/${TARGET_TRIPLE}-clang-gcc.cfg" 0
write_clang_cfg "${LLVM_BIN}/${TARGET_TRIPLE}-clang-g++.cfg" 1
write_cmake_toolchain "${MINGW_INSTALL}/toolchain.cmake"

cat >"${MINGW_INSTALL}/README.stage-mingw64" <<EOF
This overlay installs a first-pass Windows GNU target toolchain for ${TARGET_TRIPLE}.

Host output arch: ${ARCH}
Target triple: ${TARGET_TRIPLE}
GCC runtime version: ${GCC_VERSION}

The initial clang cfg files use the GCC-provided libgcc/libstdc++ runtime.
Future stages can replace that with compiler-rt/libunwind/libc++/libc++abi.
EOF

echo "-- stage-mingw64 container build ok: ${OUT_DIR}"
