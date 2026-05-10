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
  ./packages/clang/build_libcxx.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>            Runtime target, see list above
  --arch=<target>              Alias for --target
  --llvm-version=<ver>         LLVM/runtime version (default: 18.1.8)
  --bootstrap-llvm-version=<ver>
                               LLVM version already installed in the build image
                               and used for binutils-style helper tools
                               (default: 18.1.8)
  --native-stage0-archive=<tar>
                               Native clang stage0 archive
  --native-stage0-dir=<dir>    Already extracted native clang stage0 prefix
  --image=<image>              Build image
                               (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                   Parallel build jobs inside container (default: 4)
  --package-name=<name>        Override the top-level directory and tarball stem
  --pull                       Pull the selected build image before building
  --clean                      Remove this target's build and output directories first
  -h, --help                   Show this help

Outputs:
  packages/clang/build/dist/libcxx-<version>-<triple>.tar.xz
EOF
}

find_default_native_stage0_archive() {
  local archive_name="native-clang-stage0-${LLVM_VERSION}-x86_64-unknown-linux-gnu.tar.xz"
  local archive_path="${ROOT_DIR}/build/dist/${archive_name}"

  [[ -f "$archive_path" ]] || return 1
  printf '%s\n' "$archive_path"
}

extract_native_stage0_archive() {
  local archive_path="$1"
  local tmp_extract="${BUILD_DIR}.native-stage0-extract"
  local extracted_dir=""
  local package_dir="native-clang-stage0-${LLVM_VERSION}-x86_64-unknown-linux-gnu"

  [[ -f "$archive_path" ]] || die "native stage0 archive not found: ${archive_path}"

  echo "-- extracting native clang stage0 archive: ${archive_path}"
  rm -rf "$tmp_extract" "$NATIVE_STAGE0_INPUT_DIR"
  mkdir -p "$tmp_extract" "$NATIVE_STAGE0_INPUT_DIR"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${package_dir}" ]]; then
    extracted_dir="${tmp_extract}/${package_dir}"
  elif [[ -x "${tmp_extract}/bin/clang" ]]; then
    extracted_dir="$tmp_extract"
  else
    die "could not find native clang stage0 prefix in archive: ${archive_path}"
  fi

  cp -a "${extracted_dir}/." "$NATIVE_STAGE0_INPUT_DIR/"
  rm -rf "$tmp_extract"
}

validate_native_stage0_dir() {
  local stage0_dir="$1"

  [[ -d "$stage0_dir" ]] || die "native stage0 directory not found: ${stage0_dir}"
  [[ -x "${stage0_dir}/bin/clang" ]] || die "missing native stage0 clang: ${stage0_dir}/bin/clang"
  [[ -x "${stage0_dir}/bin/clang++" ]] || die "missing native stage0 clang++: ${stage0_dir}/bin/clang++"
  [[ -x "${stage0_dir}/bin/ld.lld" ]] || die "missing native stage0 ld.lld: ${stage0_dir}/bin/ld.lld"
  [[ -d "${stage0_dir}/lib/clang/${LLVM_MAJOR_VERSION}/include" ]] \
    || die "missing native stage0 clang resource headers: ${stage0_dir}"
}

TARGET=""
LLVM_VERSION="18.1.8"
LLVM_MAJOR_VERSION="${LLVM_VERSION%%.*}"
BOOTSTRAP_LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
NATIVE_STAGE0_ARCHIVE=""
NATIVE_STAGE0_DIR=""
PULL=0
CLEAN=0

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
    target=*|arch=*)
      TARGET="${1#*=}"
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
    --native-stage0-archive=*)
      NATIVE_STAGE0_ARCHIVE="${1#*=}"
      ;;
    --native-stage0-archive)
      shift
      [[ $# -gt 0 ]] || die "--native-stage0-archive requires a value"
      NATIVE_STAGE0_ARCHIVE="$1"
      ;;
    --native-stage0-dir=*)
      NATIVE_STAGE0_DIR="${1#*=}"
      ;;
    --native-stage0-dir)
      shift
      [[ $# -gt 0 ]] || die "--native-stage0-dir requires a value"
      NATIVE_STAGE0_DIR="$1"
      ;;
    --image=*)
      BUILD_IMAGE="${1#*=}"
      ;;
    --image)
      shift
      [[ $# -gt 0 ]] || die "--image requires a value"
      BUILD_IMAGE="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --package-name=*)
      PACKAGE_NAME="${1#*=}"
      ;;
    --package-name)
      shift
      [[ $# -gt 0 ]] || die "--package-name requires a value"
      PACKAGE_NAME="$1"
      ;;
    --pull)
      PULL=1
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

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "libcxx target"

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="libcxx-${LLVM_VERSION}-${SDK_PACKAGE_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/libcxx-${TARGET_TRIPLE}"
NATIVE_STAGE0_INPUT_DIR="${BUILD_DIR}/native-stage0-input"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_libcxx.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_libcxx.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning libcxx target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

if [[ -n "$NATIVE_STAGE0_ARCHIVE" && -n "$NATIVE_STAGE0_DIR" ]]; then
  die "--native-stage0-archive and --native-stage0-dir are mutually exclusive"
fi
if [[ -z "$NATIVE_STAGE0_ARCHIVE" && -z "$NATIVE_STAGE0_DIR" ]]; then
  NATIVE_STAGE0_ARCHIVE="$(find_default_native_stage0_archive)" \
    || die "native stage0 archive not provided and default archive was not found"
fi

if [[ -n "$NATIVE_STAGE0_ARCHIVE" ]]; then
  extract_native_stage0_archive "$NATIVE_STAGE0_ARCHIVE"
  validate_native_stage0_dir "$NATIVE_STAGE0_INPUT_DIR"
  NATIVE_STAGE0_MOUNT_DIR="$NATIVE_STAGE0_INPUT_DIR"
else
  [[ -d "$NATIVE_STAGE0_DIR" ]] || die "native stage0 directory not found: ${NATIVE_STAGE0_DIR}"
  NATIVE_STAGE0_MOUNT_DIR="$(cd "$NATIVE_STAGE0_DIR" && pwd)"
  validate_native_stage0_dir "$NATIVE_STAGE0_MOUNT_DIR"
fi

echo "-- libcxx build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- LLVM version: ${LLVM_VERSION}"
echo "-- bootstrap LLVM version: ${BOOTSTRAP_LLVM_VERSION}"
echo "-- native stage0: ${NATIVE_STAGE0_MOUNT_DIR}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

docker run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  -v "${NATIVE_STAGE0_MOUNT_DIR}:/work/native-stage0:ro" \
  --workdir /work \
  -e ARCH="$ARCH" \
  -e TARGET_KIND="$TARGET_KIND" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e LLVM_MAJOR_VERSION="$LLVM_MAJOR_VERSION" \
  -e BOOTSTRAP_LLVM_VERSION="$BOOTSTRAP_LLVM_VERSION" \
  -e PREBUILT_LLVM_ROOT="/opt/llvm-${BOOTSTRAP_LLVM_VERSION}" \
  -e NATIVE_STAGE0_PREFIX="/work/native-stage0" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_libcxx.sh

make_host_writable "$PACKAGE_ROOT"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- libcxx archive ready: ${ARCHIVE_PATH}"
