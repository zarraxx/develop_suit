#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

download_archive() {
  local url="$1"
  local archive_name="$2"

  mkdir -p "$CACHE_DIR"
  if [[ ! -s "${CACHE_DIR}/${archive_name}" ]]; then
    rm -f "${CACHE_DIR:?}/${archive_name}" "${CACHE_DIR}/${archive_name}.tmp"
    log "Downloading ${archive_name}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive_name}.tmp" "$url"
    mv "${CACHE_DIR}/${archive_name}.tmp" "${CACHE_DIR}/${archive_name}"
  fi
}

extract_archive_source() {
  local source_dir="$1"
  local archive_path="$2"
  local marker_path="$3"
  local archive_name=""
  local archive_marker="${source_dir}/.source-archive"

  archive_name="$(basename "$archive_path")"
  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xf "$archive_path" -C "$source_dir" --strip-components=1
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

apply_v8_patches() {
  local marker="${V8_SOURCE_DIR}/.develop-suit-v8-patches"
  local patch_file=""
  local patch_set=""
  local patch_files=()

  case "${TARGET_KIND}:${ARCH}" in
    linux:loongarch64)
      patch_files=(v8-cmake-loong64.patch)
      ;;
    linux:riscv64)
      patch_files=(v8-cmake-riscv64.patch)
      ;;
    mingw:x86_64)
      patch_files=(
        v8-mingw-export-template.patch
        v8-mingw-platform-guards.patch
        v8-mingw-disable-etw.patch
      )
      ;;
  esac

  printf -v patch_set '%s\n' "${patch_files[@]}"

  if [[ -f "$marker" ]] && ! cmp -s "$marker" <(printf '%s' "$patch_set"); then
    die "v8 source tree has a different patch set; rerun with --clean for ${TARGET_TRIPLE}"
  fi

  if [[ ! -f "$marker" ]]; then
    if [[ "${#patch_files[@]}" -eq 0 ]]; then
      log "No v8-cmake package patches needed for ${TARGET_TRIPLE}"
    else
      log "Applying v8-cmake package patches for ${TARGET_TRIPLE}"
    fi
    for patch_file in "${patch_files[@]}"; do
      (cd "$V8_SOURCE_DIR" && patch -p1 -i "${PATCH_DIR}/${patch_file}")
    done
    printf '%s' "$patch_set" >"$marker"
  fi
}

build_host_tools() {
  [[ "$TARGET_KIND" == "mingw" || "$ARCH" == "loongarch64" || "$ARCH" == "riscv64" ]] || return 0

  log "Building host V8 generator tools"
  cmake -S "$V8_SOURCE_DIR" -B "$V8_HOST_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_COMPILER="${LLVM_ROOT}/bin/clang" \
    -DCMAKE_CXX_COMPILER="${LLVM_ROOT}/bin/clang++" \
    -DCMAKE_C_FLAGS="-pthread -Wno-unused-command-line-argument" \
    -DCMAKE_CXX_FLAGS="-pthread -Wno-invalid-offsetof -Wno-deprecated-declarations -Wno-unused-command-line-argument" \
    -DCMAKE_EXE_LINKER_FLAGS="-pthread" \
    -DV8_ENABLE_I18N=OFF \
    "-DPYTHON_EXECUTABLE=$(command -v python3)"

  cmake --build "$V8_HOST_BUILD_DIR" --target bytecode_builtins_list_generator --parallel "$JOBS"
  cmake --build "$V8_HOST_BUILD_DIR" --target torque --parallel "$JOBS"
  cmake --build "$V8_HOST_BUILD_DIR" --target mksnapshot --parallel "$JOBS"
}

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"
  local extra_flags="$3"

  render_template "${TEMPLATE_DIR}/clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}" \
    "EXTRA_FLAGS=${extra_flags}" \
    "EXTRA_LINK_FLAGS=${COMMON_LDFLAGS}"
  chmod +x "$wrapper_path"
}

write_toolchain_file() {
  render_template "${TEMPLATE_DIR}/cmake-toolchain.cmake.in" "$TOOLCHAIN_FILE" \
    "CMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}" \
    "CMAKE_SYSTEM_PROCESSOR=${CMAKE_SYSTEM_PROCESSOR}" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "LD=${LD}" \
    "NM=${NM}" \
    "OBJCOPY=${OBJCOPY}" \
    "RANLIB=${RANLIB}" \
    "STRIP=${STRIP}" \
    "SYSROOT=${SYSROOT}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_ROOT=${TARGET_ROOT}" \
    "LLVM_ROOT=${LLVM_ROOT}"
}

install_v8_headers() {
  log "Installing V8 public headers"
  mkdir -p "${SDK_PREFIX}/include"
  cp -a "${V8_SOURCE_DIR}/v8/include/." "${SDK_PREFIX}/include/"
}

install_v8_libraries() {
  local library=""

  log "Installing V8 static libraries"
  mkdir -p "${SDK_PREFIX}/lib"
  for library in \
      libv8_base_without_compiler.a \
      libv8_compiler.a \
      libv8_initializers.a \
      libv8_inspector.a \
      libv8_libbase.a \
      libv8_libplatform.a \
      libv8_libsampler.a \
      libv8_snapshot.a \
      libv8_torque_generated.a; do
    [[ -f "${V8_BUILD_DIR}/${library}" ]] || die "missing V8 library: ${library}"
    cp -f "${V8_BUILD_DIR}/${library}" "${SDK_PREFIX}/lib/"
  done
}

install_v8_metadata() {
  local system_libs="-ldl -pthread"
  local libs=""

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    system_libs="-lwinmm -ldbghelp -lws2_32"
  fi
  libs="-Wl,--start-group -lv8_snapshot -lv8_initializers -lv8_compiler -lv8_base_without_compiler -lv8_torque_generated -lv8_inspector -lv8_libplatform -lv8_libsampler -lv8_libbase -Wl,--end-group ${system_libs}"

  log "Installing V8 package metadata"
  mkdir -p "${SDK_PREFIX}/lib/pkgconfig" "${SDK_PREFIX}/lib/cmake/V8"

  render_template "${TEMPLATE_DIR}/v8.pc.in" "${SDK_PREFIX}/lib/pkgconfig/v8.pc" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "V8_VERSION=${V8_VERSION}" \
    "V8_LIBS=${libs}"

  render_template "${TEMPLATE_DIR}/V8Config.cmake.in" "${SDK_PREFIX}/lib/cmake/V8/V8Config.cmake" \
    "V8_VERSION=${V8_VERSION}" \
    "V8_SYSTEM_LIBS=${system_libs// /;}"
}

validate_v8() {
  [[ -f "${SDK_PREFIX}/include/v8.h" ]] || die "missing V8 public header"
  [[ -f "${SDK_PREFIX}/include/libplatform/libplatform.h" ]] || die "missing V8 libplatform header"
  [[ -f "${SDK_PREFIX}/lib/libv8_snapshot.a" ]] || die "missing V8 snapshot library"
  [[ -f "${SDK_PREFIX}/lib/pkgconfig/v8.pc" ]] || die "missing V8 pkg-config file"
  [[ -f "${SDK_PREFIX}/lib/cmake/V8/V8Config.cmake" ]] || die "missing V8 CMake config"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
V8_VERSION="${V8_VERSION:-11.6.189.4}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/v8-${V8_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "container_v8 currently supports x86_64/riscv64/loongarch64 Linux and x86_64 MinGW" ;;
esac
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing V8 package prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command cmake
require_command ninja
require_command patch
require_command pkg-config

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CMAKE_SYSTEM_NAME="Linux"
    CMAKE_SYSTEM_PROCESSOR="$ARCH"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

DEP_SOURCE_DIR="${BUILD_DIR}/src"
DEP_BUILD_DIR="${BUILD_DIR}/build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"
TOOLCHAIN_FILE="${BUILD_TOOLS}/cmake-toolchain.cmake"
V8_SOURCE_DIR="${DEP_SOURCE_DIR}/v8-cmake"
V8_BUILD_DIR="${DEP_BUILD_DIR}/v8-cmake"
V8_HOST_BUILD_DIR="${DEP_BUILD_DIR}/v8-cmake-host"

mkdir -p "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS" "${SDK_PREFIX}/lib"
write_noop_ldconfig_wrapper "$BUILD_TOOLS"

if [[ "$TARGET_KIND" == "mingw" ]]; then
  CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
  CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
else
  CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang}"
  CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang++}"
fi
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
LD="${LD:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ld}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$LD" ]] || LD="${LLVM_ROOT}/bin/ld.lld"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$OBJCOPY" ]] || OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy"

COMMON_CFLAGS="-Wno-unused-command-line-argument"
COMMON_CXXFLAGS="-Wno-invalid-offsetof -Wno-deprecated-declarations -Wno-unused-command-line-argument"
COMMON_LDFLAGS=""
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_CFLAGS="-fPIC -pthread ${COMMON_CFLAGS}"
  COMMON_CXXFLAGS="-fPIC -pthread ${COMMON_CXXFLAGS}"
  COMMON_LDFLAGS="-pthread -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi
if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "riscv64" ]]; then
  COMMON_CFLAGS="-mno-relax ${COMMON_CFLAGS}"
  COMMON_CXXFLAGS="-mno-relax ${COMMON_CXXFLAGS}"
  COMMON_LDFLAGS="-Wl,--no-relax ${COMMON_LDFLAGS}"
fi

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-clang" "${LLVM_ROOT}/bin/clang" "$COMMON_CFLAGS"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-clang"
fi
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-clang++" "${LLVM_ROOT}/bin/clang++" "$COMMON_CXXFLAGS"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-clang++"
fi
[[ -x "$CC" ]] || die "missing target C compiler: ${CC}"
[[ -x "$CXX" ]] || die "missing target C++ compiler: ${CXX}"

export PATH="${V8_HOST_BUILD_DIR}:${V8_BUILD_DIR}:${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
export PKG_CONFIG_SYSROOT_DIR=

write_toolchain_file

V8_ARCHIVE_NAME="v8-cmake-${V8_VERSION}.tar.gz"
if [[ -z "${V8_ARCHIVE:-}" ]]; then
  V8_ARCHIVE="${CACHE_DIR}/${V8_ARCHIVE_NAME}"
  download_archive "https://github.com/bnoordhuis/v8-cmake/archive/refs/tags/${V8_VERSION}.tar.gz" "$V8_ARCHIVE_NAME"
fi
[[ -f "$V8_ARCHIVE" ]] || die "missing v8-cmake archive: ${V8_ARCHIVE}"

extract_archive_source "$V8_SOURCE_DIR" "$V8_ARCHIVE" "CMakeLists.txt"
apply_v8_patches
build_host_tools

target_cmake_args=()
if [[ "$TARGET_KIND" == "mingw" ]]; then
  target_cmake_args+=("-DV8_ENABLE_SYSTEM_INSTRUMENTATION=OFF")
fi

log "Configuring v8-cmake ${V8_VERSION}"
cmake -S "$V8_SOURCE_DIR" -B "$V8_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
  -DCMAKE_MODULE_LINKER_FLAGS="$COMMON_LDFLAGS" \
  -DV8_ENABLE_I18N=OFF \
  "${target_cmake_args[@]}" \
  "-DPYTHON_EXECUTABLE=$(command -v python3)"

log "Building V8 libraries and d8 smoke binary"
cmake --build "$V8_BUILD_DIR" --target v8_snapshot --parallel "$JOBS"
cmake --build "$V8_BUILD_DIR" --target d8 --parallel "$JOBS"
if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" ]]; then
  "${V8_BUILD_DIR}/d8" -e "if (6 * 7 !== 42) throw new Error('bad arithmetic')"
else
  log "Skipping d8 smoke test for non-native target ${TARGET_TRIPLE}"
fi

install_v8_headers
install_v8_libraries
install_v8_metadata
validate_v8

render_template "${TEMPLATE_DIR}/README.v8.in" "${SDK_PREFIX}/README.v8" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "V8_VERSION=${V8_VERSION}" \
  "LLVM_VERSION=${LLVM_VERSION}"

log "V8 package ready: ${SDK_PREFIX}"
