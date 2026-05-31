#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
SHELL_TOOLS_DIR="${PROJECT_ROOT}/packages/shell_tools"

source "${SHELL_TOOLS_DIR}/var.sh"
source "${SHELL_TOOLS_DIR}/tools.sh"

usage() {
  cat <<'EOF'
Usage:
  ./packages/perl/build_mingw64.sh [options]

Options:
  --perl-version=<ver>               Perl version (default: 5.42.2)
  --llvm-archive=<tar>               Windows clang SDK archive
  --python-deps-archive=<tar>        pyhton_dependencies-3 Windows archive
  --python-deps-dir=<dir>            Already extracted pyhton_dependencies-3 prefix
  --perl-archive=<tar>               Use a local Perl source archive
  --jobs=<n>                         Parallel build jobs (default: 1)
  --package-name=<name>              Override the top-level output directory name
  --wine-prefix=<dir>                Wine prefix to use
  --clean                            Remove the MinGW build/work/output first
  -h, --help                         Show this help

Outputs:
  packages/perl/build/out/perl-<version>-x86_64-w64-windows-gnu
  packages/perl/build/dist/perl-<version>-x86_64-w64-windows-gnu.tar.xz
EOF
}

download_if_missing() {
  local url="$1"
  local output_path="$2"

  mkdir -p "$(dirname "$output_path")"
  if [[ ! -s "$output_path" ]]; then
    rm -f "${output_path}" "${output_path}.tmp"
    curl -L --fail --retry 3 -o "${output_path}.tmp" "$url"
    mv "${output_path}.tmp" "$output_path"
  fi
}

copy_or_extract_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local tmp_extract="${output_dir}.base-extract"
  local extracted_dir=""

  rm -rf "$output_dir" "$tmp_extract"
  mkdir -p "$output_dir"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "python dependency prefix not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
    return 0
  fi

  [[ -f "$archive_path" ]] || die "python dependency archive not found: ${archive_path}"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"
  extracted_dir="$(
    find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d -print | sort | head -n 1
  )"
  [[ -n "$extracted_dir" ]] || die "could not find extracted dependency prefix in ${archive_path}"
  cp -a "${extracted_dir}/." "$output_dir/"
  rm -rf "$tmp_extract"
}

validate_windows_prefix() {
  local dir="$1"

  [[ -d "$dir" ]] || die "prefix not found: ${dir}"
  [[ -f "${dir}/README.python-dependencies" ]] || die "missing python dependency marker: ${dir}/README.python-dependencies"
  [[ -d "${dir}/bin" ]] || die "missing prefix bin directory: ${dir}/bin"
  [[ -d "${dir}/include" ]] || die "missing prefix include directory: ${dir}/include"
  [[ -d "${dir}/lib" ]] || die "missing prefix lib directory: ${dir}/lib"
}

extract_archive_tree() {
  local archive_path="$1"
  local dest_dir="$2"
  local expected_path="$3"
  local marker_path="${dest_dir}/.source-archive"
  local archive_name=""

  archive_name="$(basename "$archive_path")"
  if [[ ! -e "${dest_dir}/${expected_path}" ]] \
      || [[ ! -f "$marker_path" ]] \
      || ! grep -qx "$archive_name" "$marker_path"; then
    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"
    tar -xf "$archive_path" -C "$dest_dir"
    printf '%s\n' "$archive_name" >"$marker_path"
  fi

  [[ -e "${dest_dir}/${expected_path}" ]] || die "invalid extracted tree: ${dest_dir}"
}

write_batch_wrapper() {
  local wrapper_path="$1"
  local target_name="$2"

  printf '@echo off\r\n"%%~dp0%s" %%*\r\n' "$target_name" >"$wrapper_path"
}

apply_mingw_source_patches() {
  require_command patch

  (
    cd "$SOURCE_DIR"
    if [[ ! -f .llvmsdk-perl-win32-coreheaders-xcopy.patch.applied ]]; then
      patch -p1 -i "${ROOT_DIR}/mount_root/patch/perl-win32-coreheaders-xcopy.patch"
      touch .llvmsdk-perl-win32-coreheaders-xcopy.patch.applied
    fi
  )
}

prepare_host_mingw_dlltool() {
  local apt_cache_dir=""
  local deb_path=""

  if command -v x86_64-w64-mingw32-dlltool >/dev/null 2>&1; then
    HOST_MINGW_DLLTOOL="$(command -v x86_64-w64-mingw32-dlltool)"
    return 0
  fi

  require_command apt
  require_command dpkg-deb

  HOST_MINGW_BINUTILS_DIR="${WORK_ROOT}/host-mingw-binutils"
  HOST_MINGW_DLLTOOL="${HOST_MINGW_BINUTILS_DIR}/usr/bin/x86_64-w64-mingw32-dlltool"
  if [[ -x "$HOST_MINGW_DLLTOOL" ]]; then
    return 0
  fi

  apt_cache_dir="${CACHE_DIR}/apt-mingw-w64"
  mkdir -p "$apt_cache_dir"

  if ! compgen -G "${apt_cache_dir}/binutils-mingw-w64-x86-64_*.deb" >/dev/null; then
    (
      cd "$apt_cache_dir"
      apt download binutils-mingw-w64-x86-64
    )
  fi

  deb_path="$(
    find "$apt_cache_dir" -maxdepth 1 -type f -name 'binutils-mingw-w64-x86-64_*.deb' -print | sort | tail -n 1
  )"
  [[ -n "$deb_path" ]] || die "could not download binutils-mingw-w64-x86-64"

  rm -rf "$HOST_MINGW_BINUTILS_DIR"
  mkdir -p "$HOST_MINGW_BINUTILS_DIR"
  dpkg-deb -x "$deb_path" "$HOST_MINGW_BINUTILS_DIR"
  [[ -x "$HOST_MINGW_DLLTOOL" ]] || die "missing host dlltool after extracting ${deb_path}"
}

prepare_windows_toolchain() {
  extract_archive_tree "$LLVM_ARCHIVE" "$WORK_ROOT/toolchain" "${LLVM_ARCHIVE_STEM}/bin/x86_64-w64-windows-gnu-clang-gcc.exe"
  TOOLCHAIN_ROOT="${WORK_ROOT}/toolchain/${LLVM_ARCHIVE_STEM}"
  TOOLCHAIN_BIN="${TOOLCHAIN_ROOT}/bin"

  rm -rf "${WORK_ROOT}/msys2"
  mkdir -p "${WORK_ROOT}/msys2"
  tar --zstd -xf "$MSYS2_MAKE_ARCHIVE" -C "${WORK_ROOT}/msys2"
  tar --zstd -xf "$MSYS2_BINUTILS_ARCHIVE" -C "${WORK_ROOT}/msys2"

  cp -f "${WORK_ROOT}/msys2/mingw64/bin/"*.exe "$TOOLCHAIN_BIN/"
  cp -f "${TOOLCHAIN_BIN}/llvm-ar.exe" "${TOOLCHAIN_BIN}/ar.exe"
  cp -f "${TOOLCHAIN_BIN}/llvm-ranlib.exe" "${TOOLCHAIN_BIN}/ranlib.exe"

  write_batch_wrapper "${TOOLCHAIN_BIN}/gcc.bat" "x86_64-w64-windows-gnu-clang-gcc.exe"
  write_batch_wrapper "${TOOLCHAIN_BIN}/g++.bat" "x86_64-w64-windows-gnu-clang-g++.exe"
  write_batch_wrapper "${TOOLCHAIN_BIN}/gmake.bat" "mingw32-make.exe"
}

prepare_perl_source() {
  local marker_path="${SOURCE_DIR}/.source-archive"
  local archive_name=""

  archive_name="$(basename "$PERL_ARCHIVE")"
  if [[ ! -e "${SOURCE_DIR}/win32/GNUmakefile" ]] \
      || [[ ! -f "$marker_path" ]] \
      || ! grep -qx "$archive_name" "$marker_path"; then
    rm -rf "$SOURCE_DIR"
    mkdir -p "$SOURCE_DIR"
    tar -xf "$PERL_ARCHIVE" -C "$SOURCE_DIR" --strip-components=1
    printf '%s\n' "$archive_name" >"$marker_path"
  fi

  mkdir -p "${SOURCE_DIR}/lib/CORE"
  [[ -f "${SOURCE_DIR}/win32/GNUmakefile" ]] || die "missing GNUmakefile in extracted Perl source"
}

write_windows_build_prelude() {
  local build_cmd="$1"
  local toolchain_bin_win="$2"
  local prefix_bin_win="$3"
  local source_win32_win="$4"

  printf '@echo off\r\n' >"$build_cmd"
  printf 'setlocal\r\n' >>"$build_cmd"
  printf 'set PATH=%s;%s;%%PATH%%\r\n' "$toolchain_bin_win" "$prefix_bin_win" >>"$build_cmd"
  printf 'cd /d %s\r\n' "$source_win32_win" >>"$build_cmd"
}

run_mingw_bootstrap() {
  local toolchain_bin_win=""
  local toolchain_root_win=""
  local prefix_win=""
  local prefix_bin_win=""
  local source_win32_win=""
  local build_cmd=""

  toolchain_bin_win="$(winepath -w "$TOOLCHAIN_BIN")"
  toolchain_root_win="$(winepath -w "$TOOLCHAIN_ROOT")"
  prefix_win="$(winepath -w "$OUT_DIR")"
  prefix_bin_win="$(winepath -w "${OUT_DIR}/bin")"
  source_win32_win="$(winepath -w "${SOURCE_DIR}/win32")"
  build_cmd="${WORK_ROOT}/bootstrap-perl-mingw64.cmd"

  write_windows_build_prelude "$build_cmd" "$toolchain_bin_win" "$prefix_bin_win" "$source_win32_win"
  printf 'mingw32-make.exe perldll.def CCTYPE=GCC CCHOME=%s INST_TOP=%s INST_VER= INST_ARCH= SKIP_CCHOME_CHECK=define\r\n' "$toolchain_root_win" "$prefix_win" >>"$build_cmd"
  printf 'if errorlevel 1 exit /b %%errorlevel%%\r\n' >>"$build_cmd"

  env \
    WINEDEBUG=-all \
    WINEPREFIX="$WINE_PREFIX" \
    WINEPATH="${toolchain_bin_win};${prefix_bin_win}" \
    wine cmd /c "$(winepath -w "$build_cmd")"
}

generate_import_library() {
  local def_path="${SOURCE_DIR}/win32/perldll.def"
  local implib_path="${SOURCE_DIR}/lib/CORE/lib${PERL_DLL_BASENAME}.a"
  local explib_path="${SOURCE_DIR}/lib/CORE/${PERL_DLL_BASENAME}.exp"

  [[ -f "$def_path" ]] || die "missing Perl definition file: ${def_path}"
  "$HOST_MINGW_DLLTOOL" \
    -k \
    -d "$def_path" \
    -D "${PERL_DLL_BASENAME}.dll" \
    -l "$implib_path" \
    -e "$explib_path"
  [[ -f "$implib_path" ]] || die "missing generated import library: ${implib_path}"
  [[ -f "$explib_path" ]] || die "missing generated export library: ${explib_path}"
}

run_mingw_build() {
  local toolchain_bin_win=""
  local toolchain_root_win=""
  local prefix_win=""
  local prefix_bin_win=""
  local source_win32_win=""
  local build_cmd=""

  toolchain_bin_win="$(winepath -w "$TOOLCHAIN_BIN")"
  toolchain_root_win="$(winepath -w "$TOOLCHAIN_ROOT")"
  prefix_win="$(winepath -w "$OUT_DIR")"
  prefix_bin_win="$(winepath -w "${OUT_DIR}/bin")"
  source_win32_win="$(winepath -w "${SOURCE_DIR}/win32")"
  build_cmd="${WORK_ROOT}/build-perl-mingw64.cmd"

  write_windows_build_prelude "$build_cmd" "$toolchain_bin_win" "$prefix_bin_win" "$source_win32_win"
  printf 'mingw32-make.exe -j%d CCTYPE=GCC CCHOME=%s INST_TOP=%s INST_VER= INST_ARCH= SKIP_CCHOME_CHECK=define\r\n' "$JOBS" "$toolchain_root_win" "$prefix_win" >>"$build_cmd"
  printf 'if errorlevel 1 exit /b %%errorlevel%%\r\n' >>"$build_cmd"
  printf 'mingw32-make.exe CCTYPE=GCC CCHOME=%s INST_TOP=%s INST_VER= INST_ARCH= SKIP_CCHOME_CHECK=define install\r\n' "$toolchain_root_win" "$prefix_win" >>"$build_cmd"
  printf 'if errorlevel 1 exit /b %%errorlevel%%\r\n' >>"$build_cmd"

  env \
    WINEDEBUG=-all \
    WINEPREFIX="$WINE_PREFIX" \
    WINEPATH="${toolchain_bin_win};${prefix_bin_win}" \
    wine cmd /c "$(winepath -w "$build_cmd")"
}

sync_mingw_runtime_dlls() {
  local out_bin_dir="${OUT_DIR}/bin"
  local runtime_dll=""

  mkdir -p "$out_bin_dir"
  for runtime_dll in \
    libc++.dll \
    libunwind.dll \
    libstdc++-6.dll \
    libgcc_s_seh-1.dll \
    libgcc_s_sjlj-1.dll \
    libgcc_s_dw2-1.dll \
    libwinpthread-1.dll; do
    if [[ -f "${TOOLCHAIN_BIN}/${runtime_dll}" ]]; then
      cp -f "${TOOLCHAIN_BIN}/${runtime_dll}" "${out_bin_dir}/${runtime_dll}"
    fi
  done
}

validate_built_perl() {
  local perl_exe="${OUT_DIR}/bin/perl.exe"
  local out_bin_win=""

  [[ -f "$perl_exe" ]] || die "missing built Perl executable: ${perl_exe}"
  out_bin_win="$(winepath -w "${OUT_DIR}/bin")"

  env \
    WINEDEBUG=-all \
    WINEPREFIX="$WINE_PREFIX" \
    WINEPATH="${out_bin_win}" \
    wine "$perl_exe" -e "print qq(perl smoke ok\\n)"
}

TARGET_TRIPLE="x86_64-w64-windows-gnu"
PERL_VERSION="5.42.2"
JOBS="1"
PACKAGE_NAME=""
LLVM_ARCHIVE=""
PYTHON_DEPS_ARCHIVE=""
PYTHON_DEPS_DIR=""
PERL_ARCHIVE=""
WINE_PREFIX=""
CLEAN=0
HOST_MINGW_BINUTILS_DIR=""
HOST_MINGW_DLLTOOL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --perl-version=*) PERL_VERSION="${1#*=}" ;;
    --perl-version)
      shift
      [[ $# -gt 0 ]] || die "--perl-version requires a value"
      PERL_VERSION="$1"
      ;;
    --llvm-archive=*) LLVM_ARCHIVE="${1#*=}" ;;
    --llvm-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvm-archive requires a value"
      LLVM_ARCHIVE="$1"
      ;;
    --python-deps-archive=*|--dependency-archive=*) PYTHON_DEPS_ARCHIVE="${1#*=}" ;;
    --python-deps-archive|--dependency-archive)
      shift
      [[ $# -gt 0 ]] || die "--python-deps-archive requires a value"
      PYTHON_DEPS_ARCHIVE="$1"
      ;;
    --python-deps-dir=*|--dependency-dir=*) PYTHON_DEPS_DIR="${1#*=}" ;;
    --python-deps-dir|--dependency-dir)
      shift
      [[ $# -gt 0 ]] || die "--python-deps-dir requires a value"
      PYTHON_DEPS_DIR="$1"
      ;;
    --perl-archive=*) PERL_ARCHIVE="${1#*=}" ;;
    --perl-archive)
      shift
      [[ $# -gt 0 ]] || die "--perl-archive requires a value"
      PERL_ARCHIVE="$1"
      ;;
    --jobs=*) JOBS="${1#*=}" ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --package-name=*) PACKAGE_NAME="${1#*=}" ;;
    --package-name)
      shift
      [[ $# -gt 0 ]] || die "--package-name requires a value"
      PACKAGE_NAME="$1"
      ;;
    --wine-prefix=*)
      WINE_PREFIX="${1#*=}"
      ;;
    --wine-prefix)
      shift
      [[ $# -gt 0 ]] || die "--wine-prefix requires a value"
      WINE_PREFIX="$1"
      ;;
    --clean)
      CLEAN=1
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

require_command curl
require_command tar
require_command wine
require_command winepath
require_command patch

if [[ -n "$PYTHON_DEPS_ARCHIVE" && -n "$PYTHON_DEPS_DIR" ]]; then
  die "--python-deps-archive and --python-deps-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="perl-${PERL_VERSION}-${TARGET_TRIPLE}"
fi

BUILD_ROOT="${ROOT_DIR}/build"
WORK_ROOT="${BUILD_ROOT}/mingw64-host"
SOURCE_DIR="${WORK_ROOT}/src/perl"
OUT_DIR="${BUILD_ROOT}/out/${PACKAGE_NAME}"
DIST_DIR="${BUILD_ROOT}/dist"
DIST_ARCHIVE="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

if [[ -z "$WINE_PREFIX" ]]; then
  WINE_PREFIX="${WORK_ROOT}/wineprefix"
fi

IFS=. read -r PERL_VERSION_MAJOR PERL_VERSION_MINOR _ <<<"$PERL_VERSION"
PERL_DLL_BASENAME="perl${PERL_VERSION_MAJOR}${PERL_VERSION_MINOR}"

LLVM_ARCHIVE_URL="https://github.com/zarraxx/develop_suit/releases/download/clang-18.1.8/clang-18.1.8-x86_64-w64-windows-gnu.tar.xz"
PYTHON_DEPS_ARCHIVE_URL="https://github.com/zarraxx/develop_suit/releases/download/pyhton_dependencies-3/pyhton_dependencies-3-x86_64-w64-windows-gnu.tar.xz"
MSYS2_MAKE_URL="https://repo.msys2.org/mingw/x86_64/mingw-w64-x86_64-make-4.4.1-4-any.pkg.tar.zst"
MSYS2_BINUTILS_URL="https://repo.msys2.org/mingw/x86_64/mingw-w64-x86_64-binutils-2.46-3-any.pkg.tar.zst"
PERL_ARCHIVE_URL="https://cpan.metacpan.org/authors/id/S/SH/SHAY/perl-${PERL_VERSION}.tar.gz"

CACHE_DIR="${PROJECT_ROOT}/cache"
LLVM_ARCHIVE="${LLVM_ARCHIVE:-${CACHE_DIR}/clang-18.1.8-x86_64-w64-windows-gnu.tar.xz}"
PYTHON_DEPS_ARCHIVE="${PYTHON_DEPS_ARCHIVE:-${CACHE_DIR}/pyhton_dependencies-3-x86_64-w64-windows-gnu.tar.xz}"
PERL_ARCHIVE="${PERL_ARCHIVE:-${CACHE_DIR}/perl-${PERL_VERSION}.tar.gz}"
MSYS2_MAKE_ARCHIVE="${CACHE_DIR}/mingw-w64-x86_64-make-4.4.1-4-any.pkg.tar.zst"
MSYS2_BINUTILS_ARCHIVE="${CACHE_DIR}/mingw-w64-x86_64-binutils-2.46-3-any.pkg.tar.zst"
LLVM_ARCHIVE_STEM="clang-18.1.8-x86_64-w64-windows-gnu"

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$WORK_ROOT" "$OUT_DIR" "$DIST_ARCHIVE"
fi

mkdir -p "$CACHE_DIR" "$WORK_ROOT" "$DIST_DIR"

download_if_missing "$LLVM_ARCHIVE_URL" "$LLVM_ARCHIVE"
download_if_missing "$PYTHON_DEPS_ARCHIVE_URL" "$PYTHON_DEPS_ARCHIVE"
download_if_missing "$MSYS2_MAKE_URL" "$MSYS2_MAKE_ARCHIVE"
download_if_missing "$MSYS2_BINUTILS_URL" "$MSYS2_BINUTILS_ARCHIVE"
download_if_missing "$PERL_ARCHIVE_URL" "$PERL_ARCHIVE"

prepare_windows_toolchain
prepare_host_mingw_dlltool
copy_or_extract_prefix "$OUT_DIR" "$PYTHON_DEPS_ARCHIVE" "$PYTHON_DEPS_DIR"
validate_windows_prefix "$OUT_DIR"
prepare_perl_source
apply_mingw_source_patches
run_mingw_bootstrap
generate_import_library
run_mingw_build
sync_mingw_runtime_dlls
validate_built_perl

tar -cJf "$DIST_ARCHIVE" -C "${BUILD_ROOT}/out" "$(basename "$OUT_DIR")"

echo "-- MinGW Perl build ok"
echo "-- installed under: ${OUT_DIR}"
echo "-- archive: ${DIST_ARCHIVE}"
