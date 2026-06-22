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
  ./packages/fontconfig/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>              Fontconfig target, see list above
  --arch=<target>                Alias for --target
  --fontconfig-version=<ver>     fontconfig version (default: 2.16.0)
  --freetype-version=<ver>       FreeType version (default: 2.14.2)
  --gperf-version=<ver>          build-time GNU gperf version (default: 3.1)
  --python-deps-archive=<tar>    python_dependencies archive to use as base prefix
  --python-deps-dir=<dir>        Already extracted python_dependencies prefix
  --python-deps-release-tag=<tag>
                                  Release tag used when downloading python_dependencies
                                  (default: pyhton_dependencies-3)
  --python-deps-asset-prefix=<p>  Asset prefix used when downloading python_dependencies
                                  (default: pyhton_dependencies-3)
  --llvm-version=<ver>           Bootstrap LLVM toolchain version (default: 18.1.8)
  --image=<image>                Build image
                                  (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                     Parallel build jobs inside container (default: 4)
  --package-name=<name>          Override the top-level directory and tarball stem
  --pull                         Pull the selected build image before building
  --clean                        Remove this target's build and output directories first
  -h, --help                     Show this help

Outputs:
  packages/fontconfig/build/dist/fontconfig-<fontconfig-version>-<triple>.tar.xz
EOF
}

find_local_python_deps_archive() {
  local archive_name=""
  local archive_path=""
  local archive_names=(
    "python_dependencies-${PACKAGE_TRIPLE}.tar.xz"
    "pyhton_dependencies-3-${PACKAGE_TRIPLE}.tar.xz"
    "${PYTHON_DEPS_ASSET_PREFIX}-${PACKAGE_TRIPLE}.tar.xz"
  )

  for archive_name in "${archive_names[@]}"; do
    archive_path="${PROJECT_ROOT}/packages/python_dependencies/build/dist/${archive_name}"
    if [[ -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi

    archive_path="${ROOT_DIR}/build/inputs/${archive_name}"
    if [[ -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi
  done

  archive_path="$(
    find "${PROJECT_ROOT}/tmp" \( \
        -name "python_dependencies-${PACKAGE_TRIPLE}.tar.xz" \
        -o -name "pyhton_dependencies-3-${PACKAGE_TRIPLE}.tar.xz" \
        -o -name "${PYTHON_DEPS_ASSET_PREFIX}-${PACKAGE_TRIPLE}.tar.xz" \
      \) -type f 2>/dev/null \
      | sort -r \
      | head -n 1
  )"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  return 1
}

resolve_github_repo() {
  local origin=""
  local repo="${GITHUB_REPOSITORY:-}"

  if [[ -z "$repo" ]]; then
    origin="$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null || true)"
    case "$origin" in
      git@github.com:*)
        repo="${origin#git@github.com:}"
        repo="${repo%.git}"
        ;;
      https://github.com/*)
        repo="${origin#https://github.com/}"
        repo="${repo%.git}"
        ;;
    esac
  fi

  printf '%s\n' "${repo:-zarraxx/develop_suit}"
}

download_python_deps_archive() {
  local repo=""
  local asset_name="${PYTHON_DEPS_ASSET_PREFIX}-${PACKAGE_TRIPLE}.tar.xz"
  local input_dir="${PACKAGE_ROOT}/inputs"
  local archive_path="${input_dir}/${asset_name}"
  local tmp_path="${archive_path}.tmp"
  local url=""

  mkdir -p "$input_dir"
  if [[ -s "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  repo="$(resolve_github_repo)"
  echo "-- downloading python_dependencies: ${PYTHON_DEPS_RELEASE_TAG}/${asset_name}" >&2

  if command -v gh >/dev/null 2>&1; then
    rm -f "$archive_path"
    if gh release download "$PYTHON_DEPS_RELEASE_TAG" \
        --repo "$repo" \
        --pattern "$asset_name" \
        --dir "$input_dir" >&2; then
      [[ -f "$archive_path" ]] || die "downloaded asset not found: ${archive_path}"
      printf '%s\n' "$archive_path"
      return 0
    fi
  fi

  require_command curl
  url="https://github.com/${repo}/releases/download/${PYTHON_DEPS_RELEASE_TAG}/${asset_name}"
  rm -f "$archive_path" "$tmp_path"
  curl -L --fail --retry 3 -o "$tmp_path" "$url"
  mv "$tmp_path" "$archive_path"
  printf '%s\n' "$archive_path"
}

copy_or_extract_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local marker_name="$4"
  shift 4
  local expected_dirs=("$@")
  local tmp_extract="${output_dir}.extract"
  local extracted_dir=""
  local expected_dir=""

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "dependency directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
    return 0
  fi

  [[ -f "$archive_path" ]] || die "dependency archive not found: ${archive_path}"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"
  for expected_dir in "${expected_dirs[@]}"; do
    if [[ -d "${tmp_extract}/${expected_dir}" ]]; then
      extracted_dir="${tmp_extract}/${expected_dir}"
      break
    fi
  done
  if [[ -z "$extracted_dir" && -f "${tmp_extract}/${marker_name}" ]]; then
    extracted_dir="$tmp_extract"
  fi
  [[ -n "$extracted_dir" ]] || die "could not find dependency prefix in archive: ${archive_path}"
  cp -a "${extracted_dir}/." "$output_dir/"
  rm -rf "$tmp_extract"
}

validate_python_deps_prefix() {
  local dir="$1"

  [[ -f "${dir}/README.python-dependencies" ]] || die "missing python_dependencies marker: ${dir}/README.python-dependencies"
  [[ -f "${dir}/include/expat.h" ]] || die "missing expat header from python_dependencies"
  [[ -f "${dir}/lib/pkgconfig/expat.pc" ]] || die "missing expat pkg-config file from python_dependencies"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    compgen -G "${dir}/bin/*expat*.dll" >/dev/null || die "missing expat DLL from python_dependencies"
    compgen -G "${dir}/lib/*expat*.dll.a" >/dev/null || die "missing expat import library from python_dependencies"
  else
    compgen -G "${dir}/lib/libexpat.so*" >/dev/null || die "missing expat shared library from python_dependencies"
  fi
}

TARGET=""
FONTCONFIG_VERSION="2.16.0"
FREETYPE_VERSION="2.14.2"
GPERF_VERSION="3.1"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
PYTHON_DEPS_ARCHIVE=""
PYTHON_DEPS_DIR=""
PYTHON_DEPS_RELEASE_TAG="pyhton_dependencies-3"
PYTHON_DEPS_ASSET_PREFIX="pyhton_dependencies-3"
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      TARGET="$1"
      ;;
    target=*|arch=*) TARGET="${1#*=}" ;;
    --fontconfig-version=*) FONTCONFIG_VERSION="${1#*=}" ;;
    --fontconfig-version)
      shift
      [[ $# -gt 0 ]] || die "--fontconfig-version requires a value"
      FONTCONFIG_VERSION="$1"
      ;;
    --freetype-version=*) FREETYPE_VERSION="${1#*=}" ;;
    --freetype-version)
      shift
      [[ $# -gt 0 ]] || die "--freetype-version requires a value"
      FREETYPE_VERSION="$1"
      ;;
    --gperf-version=*) GPERF_VERSION="${1#*=}" ;;
    --gperf-version)
      shift
      [[ $# -gt 0 ]] || die "--gperf-version requires a value"
      GPERF_VERSION="$1"
      ;;
    --python-deps-archive=*|--dependency-archive=*) PYTHON_DEPS_ARCHIVE="${1#*=}" ;;
    --python-deps-archive|--dependency-archive)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      PYTHON_DEPS_ARCHIVE="$1"
      ;;
    --python-deps-dir=*|--dependency-dir=*) PYTHON_DEPS_DIR="${1#*=}" ;;
    --python-deps-dir|--dependency-dir)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      PYTHON_DEPS_DIR="$1"
      ;;
    --python-deps-release-tag=*) PYTHON_DEPS_RELEASE_TAG="${1#*=}" ;;
    --python-deps-release-tag)
      shift
      [[ $# -gt 0 ]] || die "--python-deps-release-tag requires a value"
      PYTHON_DEPS_RELEASE_TAG="$1"
      ;;
    --python-deps-asset-prefix=*) PYTHON_DEPS_ASSET_PREFIX="${1#*=}" ;;
    --python-deps-asset-prefix)
      shift
      [[ $# -gt 0 ]] || die "--python-deps-asset-prefix requires a value"
      PYTHON_DEPS_ASSET_PREFIX="$1"
      ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --image=*|--linux-image=*|--mingw-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image|--mingw-image)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
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
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "fontconfig target"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "fontconfig supports x86_64/aarch64/riscv64/loongarch64 Linux and x86_64 MinGW" ;;
esac

if [[ -n "$PYTHON_DEPS_ARCHIVE" && -n "$PYTHON_DEPS_DIR" ]]; then
  die "--python-deps-archive and --python-deps-dir are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="fontconfig-${FONTCONFIG_VERSION}-${PACKAGE_TRIPLE}"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_fontconfig.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_fontconfig.sh"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR"
make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning fontconfig target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if [[ -z "$PYTHON_DEPS_ARCHIVE" && -z "$PYTHON_DEPS_DIR" ]]; then
  PYTHON_DEPS_ARCHIVE="$(find_local_python_deps_archive || true)"
  if [[ -z "$PYTHON_DEPS_ARCHIVE" ]]; then
    PYTHON_DEPS_ARCHIVE="$(download_python_deps_archive)"
  fi
fi
[[ -n "$PYTHON_DEPS_ARCHIVE" || -n "$PYTHON_DEPS_DIR" ]] \
  || die "python_dependencies input is required; pass --python-deps-archive or --python-deps-dir"

copy_or_extract_prefix "$OUT_DIR" "$PYTHON_DEPS_ARCHIVE" "$PYTHON_DEPS_DIR" \
  "README.python-dependencies" \
  "python_dependencies-${PACKAGE_TRIPLE}" \
  "pyhton_dependencies-3-${PACKAGE_TRIPLE}" \
  "$PACKAGE_NAME"
validate_python_deps_prefix "$OUT_DIR"

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- fontconfig dependency build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$PYTHON_DEPS_DIR" ]]; then
  echo "-- python_dependencies dir: ${PYTHON_DEPS_DIR}"
else
  echo "-- python_dependencies archive: ${PYTHON_DEPS_ARCHIVE}"
fi

docker run --rm \
  --platform linux/amd64 \
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro" \
  -v "${MOUNT_ROOT}:/work/mount_root:ro" \
  -v "${CACHE_DIR}:/work/cache" \
  -v "${BUILD_DIR}:/work/build" \
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}" \
  --workdir /work \
  -e ARCH="$ARCH" \
  -e TARGET_KIND="$TARGET_KIND" \
  -e TARGET_TRIPLE="$TARGET_TRIPLE" \
  -e LLVM_VERSION="$LLVM_VERSION" \
  -e FONTCONFIG_VERSION="$FONTCONFIG_VERSION" \
  -e FREETYPE_VERSION="$FREETYPE_VERSION" \
  -e GPERF_VERSION="$GPERF_VERSION" \
  -e JOBS="$JOBS" \
  -e SDK_PREFIX="/opt/${PACKAGE_NAME}" \
  "$BUILD_IMAGE" \
  /bin/bash /work/mount_root/container_fontconfig.sh

make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_DIR"
normalize_package_permissions "$OUT_DIR"
if find "$OUT_DIR" ! -type l -perm -0002 -print -quit | grep -q .; then
  normalize_package_permissions "$OUT_DIR"
fi
if find "$OUT_DIR" ! -type l -perm -0002 -print -quit | grep -q .; then
  die "world-writable files remain after permission normalization: ${OUT_DIR}"
fi

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"
chmod 644 "$ARCHIVE_PATH"

echo "-- fontconfig archive ready: ${ARCHIVE_PATH}"
