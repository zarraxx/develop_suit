#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage_tools/build.sh --arch=<arch> [options]

Options:
  --arch=<arch>       Target arch: x86_64, aarch64, riscv64, loongarch64
  --image=<image>     Builder image
                      (default: ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-04)
  --jobs=<n>          Parallel build jobs inside container (default: 4)
  --pull              Pull the builder image before running
  --clean             Remove this arch's build/output directories before running
  --refresh-deps      Re-copy /usr from the target-arch image
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

container_remove_path() {
  local mount_dir="$1"
  local rel_path="$2"

  [[ -d "$mount_dir" ]] || return 0

  docker run --rm \
    --platform linux/amd64 \
    -v "${mount_dir}:/work/stage-tools-clean" \
    "$IMAGE" \
    /bin/sh -c "rm -rf \"/work/stage-tools-clean/${rel_path}\"" \
    >/dev/null || true
}

make_host_writable() {
  local path="$1"

  [[ -d "$path" ]] || return 0

  chmod -R a+rwX "$path" 2>/dev/null || true
  if command -v podman >/dev/null 2>&1; then
    podman unshare chmod -R a+rwX "$path" 2>/dev/null || true
  fi
}

remove_host_path() {
  local path="$1"

  rm -rf "$path" 2>/dev/null || true
  if [[ -e "$path" ]] && command -v podman >/dev/null 2>&1; then
    podman unshare rm -rf "$path" 2>/dev/null || true
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

platform_for_arch() {
  case "$1" in
    x86_64)
      echo "linux/amd64"
      ;;
    aarch64)
      echo "linux/arm64"
      ;;
    riscv64)
      echo "linux/riscv64"
      ;;
    loongarch64)
      echo "linux/loong64"
      ;;
    *)
      die "no docker platform mapping for arch: $1"
      ;;
  esac
}

prepare_target_deps() {
  local deps_dir="$1"
  local platform="$2"
  local tmp_dir="${deps_dir}.tmp"
  local marker="${deps_dir}/.stage-tools-deps-ready"
  local deps_version="stage-tools-deps-v5"
  local deps_container=""

  if [[ "$REFRESH_DEPS" -eq 0 && -f "$marker" ]] \
      && grep -qx "image=${IMAGE}" "$marker" \
      && grep -qx "platform=${platform}" "$marker" \
      && grep -qx "version=${deps_version}" "$marker"; then
    echo "-- target deps already prepared: ${deps_dir}"
    return 0
  fi

  echo "-- preparing target deps from image /usr"
  echo "-- deps platform: ${platform}"
  echo "-- deps output: ${deps_dir}"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  deps_container="$(
    docker create \
      --platform "$platform" \
      "$IMAGE" \
      /bin/sh -c true
  )"

  if ! docker cp "${deps_container}:/usr" "$tmp_dir"; then
    docker rm -f "$deps_container" >/dev/null 2>&1 || true
    return 1
  fi
  docker rm -f "$deps_container" >/dev/null 2>&1 || true
  deps_container=""

  sanitize_target_deps_usr "${tmp_dir}/usr"

  rm -rf "$deps_dir"
  mv "$tmp_dir" "$deps_dir"
  {
    echo "image=${IMAGE}"
    echo "platform=${platform}"
    echo "version=${deps_version}"
  } >"$marker"
}

sanitize_target_deps_usr() {
  local usr_dir="$1"
  local lib_dir=""

  for lib_dir in "${usr_dir}/lib" "${usr_dir}/lib64"; do
    [[ -d "$lib_dir" ]] || continue

    # The copied /usr is only used as a package dependency prefix.  Keep
    # third-party libs from the image, but never let its libc/loader/crt files
    # override the real target sysroot.
    find "$lib_dir" -maxdepth 1 \
      \( \
        -name 'ld-*.so' \
        -o -name 'ld-linux*.so*' \
        -o -name 'crt1.o' \
        -o -name 'crti.o' \
        -o -name 'crtn.o' \
        -o -name 'gcrt1.o' \
        -o -name 'Scrt1.o' \
        -o -name 'rcrt1.o' \
        -o -name 'Mcrt1.o' \
        -o -name 'libBrokenLocale.so*' \
        -o -name 'libBrokenLocale.a' \
        -o -name 'libanl.so*' \
        -o -name 'libanl.a' \
        -o -name 'libc.so*' \
        -o -name 'libc.a' \
        -o -name 'libc_nonshared.a' \
        -o -name 'libcrypt.so*' \
        -o -name 'libcrypt.a' \
        -o -name 'libdl.so*' \
        -o -name 'libdl.a' \
        -o -name 'libm.so*' \
        -o -name 'libm.a' \
        -o -name 'libmcheck.a' \
        -o -name 'libmvec.so*' \
        -o -name 'libmvec.a' \
        -o -name 'libnsl.so*' \
        -o -name 'libnsl.a' \
        -o -name 'libpthread.so*' \
        -o -name 'libpthread.a' \
        -o -name 'libresolv.so*' \
        -o -name 'libresolv.a' \
        -o -name 'librpcsvc.a' \
        -o -name 'librt.so*' \
        -o -name 'librt.a' \
        -o -name 'libthread_db.so*' \
        -o -name 'libthread_db.a' \
        -o -name 'libutil.so*' \
        -o -name 'libutil.a' \
        -o -name 'libg.a' \
      \) -exec rm -f {} +
  done
}

ARCH=""
IMAGE="ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-04"
JOBS=4
PULL=0
CLEAN=0
REFRESH_DEPS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch=*)
      ARCH="${1#*=}"
      ;;
    --arch)
      shift
      [[ $# -gt 0 ]] || die "--arch requires a value"
      ARCH="$1"
      ;;
    arch=*)
      ARCH="${1#*=}"
      ;;
    --image=*)
      IMAGE="${1#*=}"
      ;;
    --image)
      shift
      [[ $# -gt 0 ]] || die "--image requires a value"
      IMAGE="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --pull)
      PULL=1
      ;;
    --clean)
      CLEAN=1
      ;;
    --refresh-deps)
      REFRESH_DEPS=1
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

[[ -n "$ARCH" ]] || die "--arch is required"
ARCH="$(normalize_arch "$ARCH")"
TARGET_PLATFORM="$(platform_for_arch "$ARCH")"

require_command docker

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${BUILD_DIR}/out/${ARCH}"
DEPS_DIR="${BUILD_DIR}/deps/${ARCH}"
CONTAINER_NAME="stage-tools-build-${ARCH}-$$"
CONTAINER_ID=""

[[ -d "$MOUNT_ROOT" ]] || die "mount root does not exist: $MOUNT_ROOT"
[[ -f "${MOUNT_ROOT}/container_build.sh" ]] || die "missing container build script: ${MOUNT_ROOT}/container_build.sh"

make_host_writable "$BUILD_DIR"
mkdir -p "$CACHE_DIR" "$BUILD_DIR/build" "$BUILD_DIR/out" "$BUILD_DIR/deps" "$OUT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning stage_tools arch build/output: ${ARCH}"
  container_remove_path "$BUILD_DIR" "build/${ARCH}"
  container_remove_path "$BUILD_DIR" "build/cmake-external/${ARCH}"
  container_remove_path "$BUILD_DIR" "out/${ARCH}"
  remove_host_path "${BUILD_DIR}/build/${ARCH}"
  remove_host_path "${BUILD_DIR}/build/cmake-external/${ARCH}"
  remove_host_path "$OUT_DIR"
  make_host_writable "$BUILD_DIR"
  mkdir -p "$OUT_DIR"
fi

cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  else
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling builder image: ${IMAGE}"
  docker pull --platform linux/amd64 "$IMAGE"
  echo "-- pulling target deps image: ${IMAGE}"
  docker pull --platform "$TARGET_PLATFORM" "$IMAGE"
fi

prepare_target_deps "$DEPS_DIR" "$TARGET_PLATFORM"

echo "-- stage_tools build"
echo "-- image: ${IMAGE}"
echo "-- arch: ${ARCH}"
echo "-- output: ${OUT_DIR}"
echo "-- deps: ${DEPS_DIR}"

CONTAINER_ID="$(
  docker create \
    --name "$CONTAINER_NAME" \
    --platform linux/amd64 \
    -v "${MOUNT_ROOT}:/work/mount_root:ro" \
    -v "${CACHE_DIR}:/work/cache" \
    -v "${BUILD_DIR}/build:/work/build" \
    -v "${BUILD_DIR}/out:/work/out" \
    -v "${BUILD_DIR}/deps:/work/deps:ro" \
    -e "STAGE_TOOLS_HOST_UID=$(id -u)" \
    -e "STAGE_TOOLS_HOST_GID=$(id -g)" \
    --workdir /work \
    "$IMAGE" \
    /work/mount_root/container_build.sh \
      --arch="$ARCH" \
      --jobs="$JOBS" \
      --cache-dir=/work/cache \
      --build-dir=/work/build \
      --out-dir="/work/out/${ARCH}" \
      --deps-dir="/work/deps/${ARCH}"
)"

docker start -a "$CONTAINER_ID"

echo "-- stage_tools build ok"
echo "-- installed tools under: ${OUT_DIR}"
