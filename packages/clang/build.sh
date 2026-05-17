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
  ./packages/clang/build.sh --target=<target> [options]

Options:
  --target=<target>            Host target for produced clang package
  --arch=<target>              Alias for --target
  --llvm-version=<ver>         LLVM/clang version (default: 18.1.8)
  --bootstrap-llvm-version=<ver>
                               LLVM version already installed in build image
                               and used for target binutils helpers (default: 18.1.8)
  --llvmsdk-archive=<tar>      Same-version llvmsdk archive for package host triple
  --llvmsdk-dir=<dir>          Already extracted same-version llvmsdk for package host triple
  --native-llvmsdk-archive=<tar>
                               Same-version x86_64 Linux llvmsdk archive for build tools
  --native-llvmsdk-dir=<dir>   Already extracted x86_64 Linux llvmsdk for build tools
  --native-stage0-archive=<tar>
                               Native x86_64 clang stage0 archive
  --native-stage0-dir=<dir>    Already extracted native x86_64 clang stage0 prefix
  --libcxx-archive=<tar>       Runtime archive to include; may be repeated
  --libcxx-dir=<dir>           Runtime directory to include; may be repeated
  --mingw-sysroot-archive=<tar>
                               Optional host-arch mingw64 sysroot archive for validation
  --mingw-sysroot-dir=<dir>    Optional extracted host-arch mingw64 sysroot prefix
  --image=<image>              Build image
                               (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                   Parallel build jobs inside container (default: 4)
  --package-name=<name>        Override the top-level directory and tarball stem
  --pull                       Pull build image before building
  --clean                      Remove this target's build and output directories first
  -h, --help                   Show this help

Outputs:
  packages/clang/build/dist/clang-<version>-<triple>.tar.xz
EOF
}

find_archive() {
  local archive_name="$1"
  local path=""
  local search_roots=(
    "${ROOT_DIR}/build/dist"
    "${PROJECT_ROOT}/packages/llvm/build/dist"
    "${PROJECT_ROOT}/packages/llvm_dependencies/build/dist"
    "${PROJECT_ROOT}/cache"
    "${PROJECT_ROOT}/tmp"
  )

  for root in "${search_roots[@]}"; do
    [[ -e "$root" ]] || continue
    path="$(find "$root" -name "$archive_name" -type f 2>/dev/null | sort -r | head -n 1)"
    if [[ -n "$path" && -f "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

copy_or_extract_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local package_dir="$4"
  local marker_path="$5"
  local tmp_extract="${output_dir}.extract"
  local extracted_dir=""

  rm -rf "$output_dir" "$tmp_extract"
  mkdir -p "$output_dir"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "input directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
  else
    [[ -f "$archive_path" ]] || die "input archive not found: ${archive_path}"
    mkdir -p "$tmp_extract"
    tar -xf "$archive_path" -C "$tmp_extract"

    if [[ -d "${tmp_extract}/${package_dir}" ]]; then
      extracted_dir="${tmp_extract}/${package_dir}"
    elif [[ -e "${tmp_extract}/${marker_path}" ]]; then
      extracted_dir="$tmp_extract"
    else
      die "could not find ${package_dir} or ${marker_path} in archive: ${archive_path}"
    fi

    cp -a "${extracted_dir}/." "$output_dir/"
    rm -rf "$tmp_extract"
  fi
}

validate_llvmsdk_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || die "llvmsdk directory not found: ${dir}"
  [[ -f "${dir}/lib/cmake/llvm/LLVMConfig.cmake" ]] || die "missing LLVMConfig.cmake in llvmsdk: ${dir}"
  [[ -x "${dir}/bin/llvm-config" || -x "${dir}/bin/llvm-config.exe" ]] || die "missing llvm-config in llvmsdk: ${dir}"
  [[ -d "${dir}/include/llvm" ]] || die "missing LLVM headers in llvmsdk: ${dir}"
}

validate_native_stage0_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || die "native stage0 directory not found: ${dir}"
  [[ -x "${dir}/bin/clang" ]] || die "missing native stage0 clang: ${dir}"
  [[ -x "${dir}/bin/clang++" ]] || die "missing native stage0 clang++: ${dir}"
  [[ -x "${dir}/bin/ld.lld" ]] || die "missing native stage0 ld.lld: ${dir}"
}

validate_libcxx_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || die "libcxx directory not found: ${dir}"
  [[ -d "${dir}/lib/clang/${LLVM_MAJOR_VERSION}" ]] || die "missing libcxx clang resource dir: ${dir}"
  [[ -d "${dir}/include/c++/v1" ]] || die "missing libc++ headers: ${dir}"
}

validate_mingw_sysroot_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || die "mingw64 sysroot directory not found: ${dir}"
  [[ -x "${dir}/bin/x86_64-w64-windows-gnu-as" ]] || die "missing host-arch mingw64 binutils: ${dir}/bin/x86_64-w64-windows-gnu-as"
  [[ -d "${dir}/sysroot/usr/x86_64-w64-windows-gnu/include" ]] || die "missing mingw CRT headers: ${dir}"
  [[ -d "${dir}/sysroot/usr/x86_64-w64-windows-gnu/lib" ]] || die "missing mingw CRT libraries: ${dir}"
}

prune_broken_symlinks() {
  local dir="$1"
  local broken_links=()
  local path=""

  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' path; do
    broken_links+=("$path")
  done < <(find "$dir" -xtype l -print0)

  if [[ "${#broken_links[@]}" -gt 0 ]]; then
    echo "-- pruning broken symlinks before packaging: ${#broken_links[@]}"
    rm -f -- "${broken_links[@]}"
  fi
}

prepare_single_input() {
  local kind="$1"
  local archive_path="$2"
  local dir_path="$3"
  local output_dir="$4"
  local package_dir="$5"
  local marker_path="$6"

  if [[ -n "$archive_path" && -n "$dir_path" ]]; then
    die "--${kind}-archive and --${kind}-dir are mutually exclusive"
  fi

  copy_or_extract_prefix "$output_dir" "$archive_path" "$dir_path" "$package_dir" "$marker_path"
}

TARGET=""
LLVM_VERSION="18.1.8"
LLVM_MAJOR_VERSION="18"
BOOTSTRAP_LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
LLVMSDK_ARCHIVE=""
LLVMSDK_DIR=""
NATIVE_LLVMSDK_ARCHIVE=""
NATIVE_LLVMSDK_DIR=""
NATIVE_STAGE0_ARCHIVE=""
NATIVE_STAGE0_DIR=""
MINGW_SYSROOT_ARCHIVE=""
MINGW_SYSROOT_DIR=""
LIBCXX_ARCHIVES=()
LIBCXX_DIRS=()
PULL=0
CLEAN=0
NATIVE_TRIPLE="x86_64-unknown-linux-gnu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*)
      TARGET="${1#*=}"
      ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    --llvm-version=*|--unit-version=*)
      LLVM_VERSION="${1#*=}"
      LLVM_MAJOR_VERSION="${LLVM_VERSION%%.*}"
      ;;
    --llvm-version|--unit-version)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      LLVM_VERSION="$1"
      LLVM_MAJOR_VERSION="${LLVM_VERSION%%.*}"
      ;;
    --bootstrap-llvm-version=*)
      BOOTSTRAP_LLVM_VERSION="${1#*=}"
      ;;
    --bootstrap-llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--bootstrap-llvm-version requires a value"
      BOOTSTRAP_LLVM_VERSION="$1"
      ;;
    --llvmsdk-archive=*) LLVMSDK_ARCHIVE="${1#*=}" ;;
    --llvmsdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-archive requires a value"
      LLVMSDK_ARCHIVE="$1"
      ;;
    --llvmsdk-dir=*) LLVMSDK_DIR="${1#*=}" ;;
    --llvmsdk-dir)
      shift
      [[ $# -gt 0 ]] || die "--llvmsdk-dir requires a value"
      LLVMSDK_DIR="$1"
      ;;
    --native-llvmsdk-archive=*) NATIVE_LLVMSDK_ARCHIVE="${1#*=}" ;;
    --native-llvmsdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--native-llvmsdk-archive requires a value"
      NATIVE_LLVMSDK_ARCHIVE="$1"
      ;;
    --native-llvmsdk-dir=*) NATIVE_LLVMSDK_DIR="${1#*=}" ;;
    --native-llvmsdk-dir)
      shift
      [[ $# -gt 0 ]] || die "--native-llvmsdk-dir requires a value"
      NATIVE_LLVMSDK_DIR="$1"
      ;;
    --native-stage0-archive=*) NATIVE_STAGE0_ARCHIVE="${1#*=}" ;;
    --native-stage0-archive)
      shift
      [[ $# -gt 0 ]] || die "--native-stage0-archive requires a value"
      NATIVE_STAGE0_ARCHIVE="$1"
      ;;
    --native-stage0-dir=*) NATIVE_STAGE0_DIR="${1#*=}" ;;
    --native-stage0-dir)
      shift
      [[ $# -gt 0 ]] || die "--native-stage0-dir requires a value"
      NATIVE_STAGE0_DIR="$1"
      ;;
    --mingw-sysroot-archive=*) MINGW_SYSROOT_ARCHIVE="${1#*=}" ;;
    --mingw-sysroot-archive)
      shift
      [[ $# -gt 0 ]] || die "--mingw-sysroot-archive requires a value"
      MINGW_SYSROOT_ARCHIVE="$1"
      ;;
    --mingw-sysroot-dir=*) MINGW_SYSROOT_DIR="${1#*=}" ;;
    --mingw-sysroot-dir)
      shift
      [[ $# -gt 0 ]] || die "--mingw-sysroot-dir requires a value"
      MINGW_SYSROOT_DIR="$1"
      ;;
    --libcxx-archive=*)
      LIBCXX_ARCHIVES+=("${1#*=}")
      ;;
    --libcxx-archive)
      shift
      [[ $# -gt 0 ]] || die "--libcxx-archive requires a value"
      LIBCXX_ARCHIVES+=("$1")
      ;;
    --libcxx-dir=*)
      LIBCXX_DIRS+=("${1#*=}")
      ;;
    --libcxx-dir)
      shift
      [[ $# -gt 0 ]] || die "--libcxx-dir requires a value"
      LIBCXX_DIRS+=("$1")
      ;;
    --image=*) BUILD_IMAGE="${1#*=}" ;;
    --image)
      shift
      [[ $# -gt 0 ]] || die "--image requires a value"
      BUILD_IMAGE="$1"
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
    --pull) PULL=1 ;;
    --clean) CLEAN=1 ;;
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

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "clang package target"

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="clang-${LLVM_VERSION}-${PACKAGE_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/clang-${LLVM_VERSION}-${TARGET_TRIPLE}"
INPUT_DIR="${BUILD_DIR}/inputs"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_clang.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_clang.sh"

mkdir -p "$CACHE_DIR" "$PACKAGE_ROOT" "$OUT_BASE" "$DIST_DIR"
make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_DIR"
make_host_writable "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$INPUT_DIR" "$OUT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning clang target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$INPUT_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

if [[ -z "$LLVMSDK_ARCHIVE" && -z "$LLVMSDK_DIR" ]]; then
  LLVMSDK_ARCHIVE="$(find_archive "llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}.tar.xz")" \
    || die "missing llvmsdk archive for ${TARGET_TRIPLE}"
fi
if [[ -z "$NATIVE_LLVMSDK_ARCHIVE" && -z "$NATIVE_LLVMSDK_DIR" ]]; then
  NATIVE_LLVMSDK_ARCHIVE="$(find_archive "llvmsdk-${LLVM_VERSION}-${NATIVE_TRIPLE}.tar.xz")" \
    || die "missing native llvmsdk archive for ${NATIVE_TRIPLE}"
fi
if [[ -z "$NATIVE_STAGE0_ARCHIVE" && -z "$NATIVE_STAGE0_DIR" ]]; then
  NATIVE_STAGE0_ARCHIVE="$(find_archive "native-clang-stage0-${LLVM_VERSION}-${NATIVE_TRIPLE}.tar.xz")" \
    || die "missing native clang stage0 archive"
fi
default_libcxx_triples=(
  x86_64-unknown-linux-gnu
  aarch64-unknown-linux-gnu
  riscv64-unknown-linux-gnu
  loongarch64-unknown-linux-gnu
  x86_64-w64-windows-gnu
)
if [[ "${#LIBCXX_ARCHIVES[@]}" -eq 0 && "${#LIBCXX_DIRS[@]}" -eq 0 ]]; then
  for runtime_triple in "${default_libcxx_triples[@]}"; do
    runtime_archive="$(find_archive "libcxx-${LLVM_VERSION}-${runtime_triple}.tar.xz")" \
      || die "missing libcxx archive for ${runtime_triple}"
    LIBCXX_ARCHIVES+=("$runtime_archive")
  done
fi

LLVMSDK_INPUT_DIR="${INPUT_DIR}/llvmsdk"
NATIVE_LLVMSDK_INPUT_DIR="${INPUT_DIR}/native-llvmsdk"
NATIVE_STAGE0_INPUT_DIR="${INPUT_DIR}/native-stage0"
MINGW_SYSROOT_INPUT_DIR="${INPUT_DIR}/mingw64-sysroot"
LIBCXX_INPUT_ROOT="${INPUT_DIR}/libcxx"

prepare_single_input llvmsdk "$LLVMSDK_ARCHIVE" "$LLVMSDK_DIR" "$LLVMSDK_INPUT_DIR" \
  "llvmsdk-${LLVM_VERSION}-${TARGET_TRIPLE}" "lib/cmake/llvm/LLVMConfig.cmake"
validate_llvmsdk_dir "$LLVMSDK_INPUT_DIR"

prepare_single_input native-llvmsdk "$NATIVE_LLVMSDK_ARCHIVE" "$NATIVE_LLVMSDK_DIR" "$NATIVE_LLVMSDK_INPUT_DIR" \
  "llvmsdk-${LLVM_VERSION}-${NATIVE_TRIPLE}" "lib/cmake/llvm/LLVMConfig.cmake"
validate_llvmsdk_dir "$NATIVE_LLVMSDK_INPUT_DIR"

prepare_single_input native-stage0 "$NATIVE_STAGE0_ARCHIVE" "$NATIVE_STAGE0_DIR" "$NATIVE_STAGE0_INPUT_DIR" \
  "native-clang-stage0-${LLVM_VERSION}-${NATIVE_TRIPLE}" "bin/clang"
validate_native_stage0_dir "$NATIVE_STAGE0_INPUT_DIR"

MINGW_SYSROOT_PACKAGE_TRIPLE="$TARGET_TRIPLE"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  MINGW_SYSROOT_PACKAGE_TRIPLE="$NATIVE_TRIPLE"
fi

rm -rf "$MINGW_SYSROOT_INPUT_DIR"
mkdir -p "$MINGW_SYSROOT_INPUT_DIR"
if [[ -n "$MINGW_SYSROOT_ARCHIVE" || -n "$MINGW_SYSROOT_DIR" ]]; then
  prepare_single_input mingw-sysroot "$MINGW_SYSROOT_ARCHIVE" "$MINGW_SYSROOT_DIR" "$MINGW_SYSROOT_INPUT_DIR" \
    "mingw64-sysroot-${MINGW_SYSROOT_PACKAGE_TRIPLE}" "sysroot/usr/x86_64-w64-windows-gnu/include"
  validate_mingw_sysroot_dir "$MINGW_SYSROOT_INPUT_DIR"
elif MINGW_SYSROOT_ARCHIVE="$(find_archive "mingw64-sysroot-${MINGW_SYSROOT_PACKAGE_TRIPLE}.tar.xz" 2>/dev/null)"; then
  prepare_single_input mingw-sysroot "$MINGW_SYSROOT_ARCHIVE" "" "$MINGW_SYSROOT_INPUT_DIR" \
    "mingw64-sysroot-${MINGW_SYSROOT_PACKAGE_TRIPLE}" "sysroot/usr/x86_64-w64-windows-gnu/include"
  validate_mingw_sysroot_dir "$MINGW_SYSROOT_INPUT_DIR"
fi

rm -rf "$LIBCXX_INPUT_ROOT"
mkdir -p "$LIBCXX_INPUT_ROOT"
for archive_path in "${LIBCXX_ARCHIVES[@]}"; do
  package_name="$(basename "$archive_path" .tar.xz)"
  output_dir="${LIBCXX_INPUT_ROOT}/${package_name}"
  copy_or_extract_prefix "$output_dir" "$archive_path" "" "$package_name" "include/c++/v1"
  validate_libcxx_dir "$output_dir"
done
for dir_path in "${LIBCXX_DIRS[@]}"; do
  package_name="$(basename "$dir_path")"
  output_dir="${LIBCXX_INPUT_ROOT}/${package_name}"
  copy_or_extract_prefix "$output_dir" "" "$dir_path" "$package_name" "include/c++/v1"
  validate_libcxx_dir "$output_dir"
done

echo "-- clang package build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- host target: ${TARGET_TRIPLE}"
echo "-- LLVM version: ${LLVM_VERSION}"
echo "-- llvmsdk: ${LLVMSDK_INPUT_DIR}"
echo "-- native llvmsdk: ${NATIVE_LLVMSDK_INPUT_DIR}"
echo "-- native stage0: ${NATIVE_STAGE0_INPUT_DIR}"
echo "-- mingw64 sysroot: ${MINGW_SYSROOT_INPUT_DIR}"
echo "-- libcxx inputs: ${LIBCXX_INPUT_ROOT}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

docker run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  -v "${LLVMSDK_INPUT_DIR}:/work/llvmsdk:ro" \
  -v "${NATIVE_LLVMSDK_INPUT_DIR}:/work/native-llvmsdk:ro" \
  -v "${NATIVE_STAGE0_INPUT_DIR}:/work/native-stage0:ro" \
  -v "${MINGW_SYSROOT_INPUT_DIR}:/work/mingw64-sysroot:ro" \
  -v "${LIBCXX_INPUT_ROOT}:/work/libcxx:ro" \
  --workdir /work \
  -e ARCH="$ARCH" \
  -e TARGET_KIND="$TARGET_KIND" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e LLVM_MAJOR_VERSION="$LLVM_MAJOR_VERSION" \
  -e BOOTSTRAP_LLVM_VERSION="$BOOTSTRAP_LLVM_VERSION" \
  -e PREBUILT_LLVM_ROOT="/opt/llvm-${BOOTSTRAP_LLVM_VERSION}" \
  -e LLVMSDK_PREFIX="/work/llvmsdk" \
  -e NATIVE_LLVMSDK_PREFIX="/work/native-llvmsdk" \
  -e NATIVE_STAGE0_PREFIX="/work/native-stage0" \
  -e MINGW_SYSROOT_PREFIX="/work/mingw64-sysroot" \
  -e LIBCXX_INPUT_ROOT="/work/libcxx" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_clang.sh

make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_DIR"
make_host_writable "$DIST_DIR"

rm -f "$ARCHIVE_PATH"
prune_broken_symlinks "$OUT_DIR"

tar_args=(-C "$OUT_BASE" -cJf "$ARCHIVE_PATH")
if [[ "$TARGET_KIND" == "mingw" ]]; then
  tar_args=(--dereference --hard-dereference "${tar_args[@]}")
fi

tar "${tar_args[@]}" "$PACKAGE_NAME"

echo "-- clang archive ready: ${ARCHIVE_PATH}"
