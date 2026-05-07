#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage_osxcross/custom_build.sh --arch=<arch> [options]

Options:
  --arch=<arch>           Host arch for produced Linux osxcross tools:
                          x86_64, aarch64, riscv64, loongarch64
  --build-image=<image>   x86_64 build container image
                          (default: ghcr.io/zarraxx/develop_suit:llvm-18.1.8)
  --deps-rootfs-dir=<dir> host-arch stage_python rootfs directory
                          (default: <repo>/dist/stage_python/<arch>, if present)
  --deps-release-tag=<tag>
                          stage_python release tag used to fetch rootfs tarball
                          (default: stage-python-2026-05-03)
  --deps-image=<image>    optional host-arch image used only as /usr dependency source
                          (default: unset; release rootfs is used instead)
  --jobs=<n>              Parallel build jobs inside container (default: 4)
  --modules=<list>        Custom modules to run inside the container
                          (default: "xar libtapi liblto cctools";
                          available: xar libtapi liblto cctools)
  --pull                  Pull build image, and deps image when --deps-image is set
  --clean                 Remove this arch's build/output directories first
  --refresh-deps          Re-copy /usr from stage_python
  -h, --help              Show this help

This custom path intentionally runs builds in the x86_64 stage_llvm image while
using the host-arch stage_python /usr only as dependency headers/libraries.
Host-arch Python executables are removed from that dependency prefix so CMake
and configure scripts cannot accidentally execute them.
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

target_triple_for_arch() {
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
      die "no target triple mapping for arch: $1"
      ;;
  esac
}

docker_platform_for_arch() {
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

make_host_writable() {
  local path="$1"

  [[ -d "$path" ]] || return 0

  chmod -R a+rwX "$path" 2>/dev/null || true
  if command -v podman >/dev/null 2>&1; then
    podman unshare chmod -R a+rwX "$path" 2>/dev/null || true
  fi
}

sanitize_target_deps_usr() {
  local usr_dir="$1"
  local lib_dir=""

  for lib_dir in "${usr_dir}/lib" "${usr_dir}/lib64"; do
    [[ -d "$lib_dir" ]] || continue

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

  if [[ -d "${usr_dir}/bin" ]]; then
    find "${usr_dir}/bin" -maxdepth 1 \
      \( \
        -name 'python*' \
        -o -name 'pip*' \
        -o -name 'idle*' \
        -o -name '2to3*' \
        -o -name 'pydoc*' \
        -o -name 'pkg-config' \
        -o -name 'pkgconf' \
      \) -exec rm -f {} +
  fi
}

stage_python_archive_path() {
  local arch="$1"
  local release_tag="$2"
  local archive_name="stage_python-rootfs-${arch}.tar.xz"
  local archive_path="${CACHE_DIR}/${archive_name}"

  if [[ -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  require_command gh

  echo "-- downloading ${archive_name} from release ${release_tag}" >&2
  gh release download "$release_tag" \
    --repo zarraxx/develop_suit \
    --pattern "$archive_name" \
    --dir "$CACHE_DIR"

  [[ -f "$archive_path" ]] || die "downloaded archive not found: $archive_path"
  printf '%s\n' "$archive_path"
}

prepare_target_deps_from_rootfs() {
  local deps_dir="$1"
  local rootfs_dir="$2"
  local source_id="$3"
  local tmp_dir="${deps_dir}.tmp"
  local marker="${deps_dir}/.stage-osxcross-deps-ready"
  local deps_version="stage-osxcross-python-deps-v2"

  [[ -d "${rootfs_dir}/usr" ]] || die "stage_python rootfs /usr not found: ${rootfs_dir}/usr"

  if [[ "$REFRESH_DEPS" -eq 0 && -f "$marker" ]] \
      && grep -qx "source=${source_id}" "$marker" \
      && grep -qx "version=${deps_version}" "$marker"; then
    echo "-- host deps already prepared: ${deps_dir}"
    return 0
  fi

  echo "-- preparing host deps /usr from stage_python rootfs"
  echo "-- deps rootfs: ${rootfs_dir}"
  echo "-- deps output: ${deps_dir}"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  cp -a "${rootfs_dir}/usr" "$tmp_dir/"

  sanitize_target_deps_usr "${tmp_dir}/usr"

  rm -rf "$deps_dir"
  mv "$tmp_dir" "$deps_dir"
  {
    echo "source=${source_id}"
    echo "version=${deps_version}"
  } >"$marker"
}

prepare_target_deps_from_archive() {
  local deps_dir="$1"
  local archive_path="$2"
  local arch="$3"
  local tmp_extract="${deps_dir}.extract"
  local rootfs_dir=""

  echo "-- extracting stage_python rootfs archive: ${archive_path}"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"

  if [[ -d "${tmp_extract}/${arch}/usr" ]]; then
    rootfs_dir="${tmp_extract}/${arch}"
  elif [[ -d "${tmp_extract}/usr" ]]; then
    rootfs_dir="$tmp_extract"
  else
    die "could not find /usr in archive: ${archive_path}"
  fi

  prepare_target_deps_from_rootfs "$deps_dir" "$rootfs_dir" "archive=${archive_path}"
  rm -rf "$tmp_extract"
}

prepare_target_deps_from_image() {
  local deps_dir="$1"
  local deps_image="$2"
  local deps_platform="$3"
  local tmp_dir="${deps_dir}.tmp"
  local marker="${deps_dir}/.stage-osxcross-deps-ready"
  local deps_version="stage-osxcross-python-deps-v1"
  local deps_container=""

  if [[ "$REFRESH_DEPS" -eq 0 && -f "$marker" ]] \
      && grep -qx "image=${deps_image}" "$marker" \
      && grep -qx "platform=${deps_platform}" "$marker" \
      && grep -qx "version=${deps_version}" "$marker"; then
    echo "-- host deps already prepared: ${deps_dir}"
    return 0
  fi

  echo "-- preparing host deps /usr from stage_python image"
  echo "-- deps image: ${deps_image}"
  echo "-- deps platform: ${deps_platform}"
  echo "-- deps output: ${deps_dir}"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  deps_container="$(
    docker create \
      --platform "$deps_platform" \
      "$deps_image" \
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
    echo "image=${deps_image}"
    echo "platform=${deps_platform}"
    echo "version=${deps_version}"
  } >"$marker"
}

prepare_target_deps() {
  local deps_dir="$1"

  if [[ -n "$DEPS_IMAGE" ]]; then
    prepare_target_deps_from_image "$deps_dir" "$DEPS_IMAGE" "$DEPS_PLATFORM"
    return 0
  fi

  if [[ -n "$DEPS_ROOTFS_DIR" ]]; then
    prepare_target_deps_from_rootfs "$deps_dir" "$DEPS_ROOTFS_DIR" "rootfs=${DEPS_ROOTFS_DIR}"
    return 0
  fi

  local default_rootfs_dir="${PROJECT_ROOT}/dist/stage_python/${ARCH}"
  if [[ -d "${default_rootfs_dir}/usr" ]]; then
    prepare_target_deps_from_rootfs "$deps_dir" "$default_rootfs_dir" "rootfs=${default_rootfs_dir}"
    return 0
  fi

  local archive_path=""
  archive_path="$(stage_python_archive_path "$ARCH" "$DEPS_RELEASE_TAG")"
  prepare_target_deps_from_archive "$deps_dir" "$archive_path" "$ARCH"
}

ARCH=""
BUILD_IMAGE="ghcr.io/zarraxx/develop_suit:llvm-18.1.8"
DEPS_IMAGE=""
DEPS_ROOTFS_DIR=""
DEPS_RELEASE_TAG="stage-python-2026-05-03"
JOBS=4
CUSTOM_MODULES="xar libtapi liblto cctools"
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
    --build-image=*)
      BUILD_IMAGE="${1#*=}"
      ;;
    --build-image)
      shift
      [[ $# -gt 0 ]] || die "--build-image requires a value"
      BUILD_IMAGE="$1"
      ;;
    --deps-image=*)
      DEPS_IMAGE="${1#*=}"
      ;;
    --deps-image)
      shift
      [[ $# -gt 0 ]] || die "--deps-image requires a value"
      DEPS_IMAGE="$1"
      ;;
    --deps-rootfs-dir=*)
      DEPS_ROOTFS_DIR="${1#*=}"
      ;;
    --deps-rootfs-dir)
      shift
      [[ $# -gt 0 ]] || die "--deps-rootfs-dir requires a value"
      DEPS_ROOTFS_DIR="$1"
      ;;
    --deps-release-tag=*)
      DEPS_RELEASE_TAG="${1#*=}"
      ;;
    --deps-release-tag)
      shift
      [[ $# -gt 0 ]] || die "--deps-release-tag requires a value"
      DEPS_RELEASE_TAG="$1"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --jobs)
      shift
      [[ $# -gt 0 ]] || die "--jobs requires a value"
      JOBS="$1"
      ;;
    --modules=*)
      CUSTOM_MODULES="${1#*=}"
      ;;
    --modules)
      shift
      [[ $# -gt 0 ]] || die "--modules requires a value"
      CUSTOM_MODULES="$1"
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
TARGET_TRIPLE="$(target_triple_for_arch "$ARCH")"
DEPS_PLATFORM="$(docker_platform_for_arch "$ARCH")"
BUILD_PLATFORM="linux/amd64"

require_command docker

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${BUILD_DIR}/out/${ARCH}/osxcross"
DEPS_DIR="${BUILD_DIR}/deps/${ARCH}"

[[ -d "$MOUNT_ROOT" ]] || die "mount root does not exist: $MOUNT_ROOT"
[[ -f "${MOUNT_ROOT}/container_custom_build.sh" ]] || die "missing custom container build script"
[[ -d "${ROOT_DIR}/upstream" ]] || die "upstream directory does not exist: ${ROOT_DIR}/upstream"

make_host_writable "$BUILD_DIR"
mkdir -p "$CACHE_DIR" "$BUILD_DIR/build" "$BUILD_DIR/out/${ARCH}" "$DEPS_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning stage_osxcross custom build/output: ${ARCH}"
  make_host_writable "$BUILD_DIR"
  rm -rf "${BUILD_DIR}/build/${ARCH}" "$OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform "$BUILD_PLATFORM" "$BUILD_IMAGE"
  if [[ -n "$DEPS_IMAGE" ]]; then
    echo "-- pulling deps image: ${DEPS_IMAGE}"
    docker pull --platform "$DEPS_PLATFORM" "$DEPS_IMAGE"
  fi
fi

prepare_target_deps "$DEPS_DIR"

echo "-- stage_osxcross custom build"
echo "-- build image: ${BUILD_IMAGE}"
echo "-- build platform: ${BUILD_PLATFORM}"
echo "-- host arch: ${ARCH}"
echo "-- host triple: ${TARGET_TRIPLE}"
echo "-- host deps dir: ${DEPS_DIR}"
echo "-- output: ${OUT_DIR}"
echo "-- modules: ${CUSTOM_MODULES}"

docker run --rm \
  --platform "$BUILD_PLATFORM" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${ROOT_DIR}/upstream:/work/upstream:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}/build:/work/build" \
  -v "${BUILD_DIR}/out/${ARCH}/osxcross:/opt/osxcross" \
  -v "${DEPS_DIR}:/work/deps/${ARCH}:ro" \
  --workdir /work \
  -e ARCH="$ARCH" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e JOBS="$JOBS" \
  -e DEPS_DIR="/work/deps/${ARCH}" \
  -e OUT_DIR="/opt/osxcross" \
  -e CUSTOM_MODULES="$CUSTOM_MODULES" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_custom_build.sh

make_host_writable "$BUILD_DIR"

echo "-- stage_osxcross custom build ok"
echo "-- installed under: ${OUT_DIR}"
