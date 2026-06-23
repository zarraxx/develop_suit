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
  ./packages/openjdk/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>             OpenJDK target
  --arch=<target>               Alias for --target
  --openjdk-version=<ver>       OpenJDK version (default: 25.0.3;
                                loongarch64 SRPM default: 17.0.17)
  --maven-version=<ver>         Maven version copied into the package (default: 3.9.16)
  --llvm-version=<ver>          LLVM toolchain version for source builds (default: 18.1.8)
  --x64-jdk-url=<url>           x86_64 Linux prebuilt JDK archive URL
  --x64-jdk-archive=<archive>   Use local x86_64 Linux prebuilt JDK archive
  --aarch64-jdk-url=<url>       aarch64 Linux prebuilt JDK archive URL
  --aarch64-jdk-archive=<tar>   Use local aarch64 Linux prebuilt JDK archive
  --mingw64-jdk-url=<url>       x86_64 Windows prebuilt JDK archive URL
  --mingw64-jdk-archive=<zip>   Use local x86_64 Windows prebuilt JDK archive
  --fontconfig-archive=<tar>    fontconfig dependency archive for source builds
  --fontconfig-dir=<dir>        Already extracted fontconfig dependency prefix
  --fontconfig-release-tag=<tag>
                                Release tag used when downloading fontconfig
                                (default: fontconfig-2.16.0)
  --fontconfig-asset-prefix=<p> Asset prefix used when downloading fontconfig
                                (default: fontconfig-2.16.0)
  --openjdk-source-url=<url>    Source archive URL for cross source builds
                                (riscv64 default: upstream OpenJDK source;
                                loongarch64 default: Loongnix OpenJDK SRPM)
  --openjdk-archive=<tar>       Use local OpenJDK source archive
  --loongarch64-openjdk-srpm-url=<url>
                                LoongArch64 OpenJDK SRPM URL
  --loongarch64-openjdk-srpm-archive=<rpm>
                                Use local LoongArch64 OpenJDK SRPM
  --loongarch64-openjdk-patch=<patch>
                                Apply an extra LoongArch64 OpenJDK source patch
  --boot-jdk-url=<url>          Build-host Boot JDK URL for cross source builds
  --boot-jdk-archive=<tar>      Use local build-host Boot JDK archive
  --zip-url=<url>               Info-ZIP source URL for source builds
  --zip-archive=<tar>           Use local Info-ZIP source archive
  --maven-url=<url>             Maven archive URL
  --maven-archive=<zip>         Use local Maven archive
  --image=<image>               Build image
                                (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                    Parallel build jobs inside container (default: 4)
  --package-name=<name>         Override the top-level directory and tarball stem
  --pull                        Pull the selected build image before building
  --clean                       Remove this target's build and output directories first
  -h, --help                    Show this help

Outputs:
  packages/openjdk/build/dist/openjdk-<version>-<triple>.tar.xz
EOF
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

find_local_fontconfig_archive() {
  local archive_name=""
  local archive_path=""
  local archive_names=(
    "${FONTCONFIG_ASSET_PREFIX}-${PACKAGE_TRIPLE}.tar.xz"
    "fontconfig-${PACKAGE_TRIPLE}.tar.xz"
  )

  for archive_name in "${archive_names[@]}"; do
    archive_path="${PROJECT_ROOT}/packages/fontconfig/build/dist/${archive_name}"
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
        -name "${FONTCONFIG_ASSET_PREFIX}-${PACKAGE_TRIPLE}.tar.xz" \
        -o -name "fontconfig-${PACKAGE_TRIPLE}.tar.xz" \
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

download_fontconfig_archive() {
  local repo=""
  local asset_name="${FONTCONFIG_ASSET_PREFIX}-${PACKAGE_TRIPLE}.tar.xz"
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
  url="https://github.com/${repo}/releases/download/${FONTCONFIG_RELEASE_TAG}/${asset_name}"
  echo "-- downloading fontconfig dependency: ${url}" >&2
  require_command curl
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

  rm -rf "$output_dir" "$tmp_extract"
  mkdir -p "$output_dir"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "dependency directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
    return 0
  fi

  [[ -f "$archive_path" ]] || die "dependency archive not found: ${archive_path}"
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

validate_fontconfig_prefix() {
  local dir="$1"

  [[ -f "${dir}/README.fontconfig" ]] || die "missing fontconfig marker: ${dir}/README.fontconfig"
  [[ -f "${dir}/include/freetype2/ft2build.h" ]] || die "missing FreeType headers in fontconfig dependency"
  [[ -f "${dir}/include/fontconfig/fontconfig.h" ]] || die "missing fontconfig headers"
  [[ -f "${dir}/lib/pkgconfig/freetype2.pc" ]] || die "missing freetype2 pkg-config file"
  [[ -f "${dir}/lib/pkgconfig/fontconfig.pc" ]] || die "missing fontconfig pkg-config file"
  compgen -G "${dir}/lib/libfreetype.so*" >/dev/null || die "missing FreeType shared library"
  compgen -G "${dir}/lib/libfontconfig.so*" >/dev/null || die "missing fontconfig shared library"
}

TARGET=""
OPENJDK_VERSION="25.0.3"
OPENJDK_VERSION_SET=0
MAVEN_VERSION="3.9.16"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
X64_JDK_URL="https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-linux_x64.tar.gz"
X64_JDK_ARCHIVE=""
AARCH64_JDK_URL="https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-linux_aarch64.tar.gz"
AARCH64_JDK_ARCHIVE=""
MINGW64_JDK_URL="https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-win_x64.zip"
MINGW64_JDK_ARCHIVE=""
FONTCONFIG_ARCHIVE=""
FONTCONFIG_DIR=""
FONTCONFIG_RELEASE_TAG="fontconfig-2.16.0"
FONTCONFIG_ASSET_PREFIX="fontconfig-2.16.0"
OPENJDK_SOURCE_URL_DEFAULT="https://openjdk-sources.osci.io/openjdk25/openjdk-25.0.3-ga.tar.xz"
LOONGARCH64_OPENJDK_SOURCE_URL="https://github.com/loongson/jdk17u/archive/refs/tags/jdk-17.0.19+10-ls-ga.tar.gz"
LOONGARCH64_OPENJDK_SRPM_URL="https://pkg.loongnix.cn/loongnix-server/23.2/os/source/SPackages/java-17-openjdk-17.0.17.0.10-1.lns23.src.rpm"
LOONGARCH64_OPENJDK_SRPM_ARCHIVE=""
OPENJDK_SOURCE_URL="$OPENJDK_SOURCE_URL_DEFAULT"
OPENJDK_SOURCE_URL_SET=0
OPENJDK_ARCHIVE=""
LOONGARCH64_OPENJDK_PATCH=""
BOOT_JDK_URL="https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse"
BOOT_JDK_URL_SET=0
LOONGARCH64_BOOT_JDK_URL="https://cdn.azul.com/zulu/bin/zulu17.66.19-ca-jdk17.0.19-linux_x64.tar.gz"
BOOT_JDK_ARCHIVE=""
ZIP_URL="https://downloads.sourceforge.net/infozip/zip30.tar.gz"
ZIP_ARCHIVE=""
MAVEN_URL=""
MAVEN_ARCHIVE=""
PULL=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*|--arch=*) TARGET="${1#*=}" ;;
    --target|--arch)
      shift
      [[ $# -gt 0 ]] || die "--target requires a value"
      TARGET="$1"
      ;;
    --openjdk-version=*|--jdk-version=*)
      OPENJDK_VERSION="${1#*=}"
      OPENJDK_VERSION_SET=1
      ;;
    --openjdk-version|--jdk-version)
      shift
      [[ $# -gt 0 ]] || die "--openjdk-version requires a value"
      OPENJDK_VERSION="$1"
      OPENJDK_VERSION_SET=1
      ;;
    --maven-version=*) MAVEN_VERSION="${1#*=}" ;;
    --maven-version)
      shift
      [[ $# -gt 0 ]] || die "--maven-version requires a value"
      MAVEN_VERSION="$1"
      ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
      ;;
    --x64-jdk-url=*) X64_JDK_URL="${1#*=}" ;;
    --x64-jdk-url)
      shift
      [[ $# -gt 0 ]] || die "--x64-jdk-url requires a value"
      X64_JDK_URL="$1"
      ;;
    --x64-jdk-archive=*) X64_JDK_ARCHIVE="${1#*=}" ;;
    --x64-jdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--x64-jdk-archive requires a value"
      X64_JDK_ARCHIVE="$1"
      ;;
    --aarch64-jdk-url=*) AARCH64_JDK_URL="${1#*=}" ;;
    --aarch64-jdk-url)
      shift
      [[ $# -gt 0 ]] || die "--aarch64-jdk-url requires a value"
      AARCH64_JDK_URL="$1"
      ;;
    --aarch64-jdk-archive=*) AARCH64_JDK_ARCHIVE="${1#*=}" ;;
    --aarch64-jdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--aarch64-jdk-archive requires a value"
      AARCH64_JDK_ARCHIVE="$1"
      ;;
    --mingw64-jdk-url=*) MINGW64_JDK_URL="${1#*=}" ;;
    --mingw64-jdk-url)
      shift
      [[ $# -gt 0 ]] || die "--mingw64-jdk-url requires a value"
      MINGW64_JDK_URL="$1"
      ;;
    --mingw64-jdk-archive=*) MINGW64_JDK_ARCHIVE="${1#*=}" ;;
    --mingw64-jdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--mingw64-jdk-archive requires a value"
      MINGW64_JDK_ARCHIVE="$1"
      ;;
    --fontconfig-archive=*) FONTCONFIG_ARCHIVE="${1#*=}" ;;
    --fontconfig-archive)
      shift
      [[ $# -gt 0 ]] || die "--fontconfig-archive requires a value"
      FONTCONFIG_ARCHIVE="$1"
      ;;
    --fontconfig-dir=*) FONTCONFIG_DIR="${1#*=}" ;;
    --fontconfig-dir)
      shift
      [[ $# -gt 0 ]] || die "--fontconfig-dir requires a value"
      FONTCONFIG_DIR="$1"
      ;;
    --fontconfig-release-tag=*) FONTCONFIG_RELEASE_TAG="${1#*=}" ;;
    --fontconfig-release-tag)
      shift
      [[ $# -gt 0 ]] || die "--fontconfig-release-tag requires a value"
      FONTCONFIG_RELEASE_TAG="$1"
      ;;
    --fontconfig-asset-prefix=*) FONTCONFIG_ASSET_PREFIX="${1#*=}" ;;
    --fontconfig-asset-prefix)
      shift
      [[ $# -gt 0 ]] || die "--fontconfig-asset-prefix requires a value"
      FONTCONFIG_ASSET_PREFIX="$1"
      ;;
    --openjdk-source-url=*|--jdk-source-url=*)
      OPENJDK_SOURCE_URL="${1#*=}"
      OPENJDK_SOURCE_URL_SET=1
      ;;
    --openjdk-source-url|--jdk-source-url)
      shift
      [[ $# -gt 0 ]] || die "--openjdk-source-url requires a value"
      OPENJDK_SOURCE_URL="$1"
      OPENJDK_SOURCE_URL_SET=1
      ;;
    --openjdk-archive=*|--jdk-archive=*) OPENJDK_ARCHIVE="${1#*=}" ;;
    --openjdk-archive|--jdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--openjdk-archive requires a value"
      OPENJDK_ARCHIVE="$1"
      ;;
    --loongarch64-openjdk-srpm-url=*) LOONGARCH64_OPENJDK_SRPM_URL="${1#*=}" ;;
    --loongarch64-openjdk-srpm-url)
      shift
      [[ $# -gt 0 ]] || die "--loongarch64-openjdk-srpm-url requires a value"
      LOONGARCH64_OPENJDK_SRPM_URL="$1"
      ;;
    --loongarch64-openjdk-srpm-archive=*) LOONGARCH64_OPENJDK_SRPM_ARCHIVE="${1#*=}" ;;
    --loongarch64-openjdk-srpm-archive)
      shift
      [[ $# -gt 0 ]] || die "--loongarch64-openjdk-srpm-archive requires a value"
      LOONGARCH64_OPENJDK_SRPM_ARCHIVE="$1"
      ;;
    --loongarch64-openjdk-patch=*) LOONGARCH64_OPENJDK_PATCH="${1#*=}" ;;
    --loongarch64-openjdk-patch)
      shift
      [[ $# -gt 0 ]] || die "--loongarch64-openjdk-patch requires a value"
      LOONGARCH64_OPENJDK_PATCH="$1"
      ;;
    --boot-jdk-url=*)
      BOOT_JDK_URL="${1#*=}"
      BOOT_JDK_URL_SET=1
      ;;
    --boot-jdk-url)
      shift
      [[ $# -gt 0 ]] || die "--boot-jdk-url requires a value"
      BOOT_JDK_URL="$1"
      BOOT_JDK_URL_SET=1
      ;;
    --boot-jdk-archive=*) BOOT_JDK_ARCHIVE="${1#*=}" ;;
    --boot-jdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--boot-jdk-archive requires a value"
      BOOT_JDK_ARCHIVE="$1"
      ;;
    --zip-url=*) ZIP_URL="${1#*=}" ;;
    --zip-url)
      shift
      [[ $# -gt 0 ]] || die "--zip-url requires a value"
      ZIP_URL="$1"
      ;;
    --zip-archive=*) ZIP_ARCHIVE="${1#*=}" ;;
    --zip-archive)
      shift
      [[ $# -gt 0 ]] || die "--zip-archive requires a value"
      ZIP_ARCHIVE="$1"
      ;;
    --maven-url=*) MAVEN_URL="${1#*=}" ;;
    --maven-url)
      shift
      [[ $# -gt 0 ]] || die "--maven-url requires a value"
      MAVEN_URL="$1"
      ;;
    --maven-archive=*) MAVEN_ARCHIVE="${1#*=}" ;;
    --maven-archive)
      shift
      [[ $# -gt 0 ]] || die "--maven-archive requires a value"
      MAVEN_ARCHIVE="$1"
      ;;
    --image=*|--linux-image=*) BUILD_IMAGE="${1#*=}" ;;
    --image|--linux-image)
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
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || die "--target is required"
resolve_target "$TARGET" "OpenJDK target"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "OpenJDK package supports x86_64/aarch64/riscv64/loongarch64 Linux and x86_64 MinGW" ;;
esac

[[ -n "$MAVEN_URL" ]] || MAVEN_URL="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.zip"
USE_LOONGARCH64_OPENJDK_SRPM=0
if [[ "${TARGET_KIND}:${ARCH}" == "linux:loongarch64" \
    && ( -n "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE" \
      || ( "$OPENJDK_SOURCE_URL_SET" -eq 0 && -z "$OPENJDK_ARCHIVE" ) ) ]]; then
  USE_LOONGARCH64_OPENJDK_SRPM=1
  if [[ "$OPENJDK_VERSION_SET" -eq 0 ]]; then
    OPENJDK_VERSION="17.0.17"
  fi
fi
if [[ "${TARGET_KIND}:${ARCH}" == "linux:loongarch64" && "$BOOT_JDK_URL_SET" -eq 0 ]]; then
  BOOT_JDK_URL="$LOONGARCH64_BOOT_JDK_URL"
fi
if [[ "$USE_LOONGARCH64_OPENJDK_SRPM" -eq 0 ]]; then
  LOONGARCH64_OPENJDK_SRPM_URL=""
  LOONGARCH64_OPENJDK_SRPM_ARCHIVE=""
elif [[ -n "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE" && -n "$OPENJDK_ARCHIVE" ]]; then
  die "--loongarch64-openjdk-srpm-archive and --openjdk-archive are mutually exclusive"
elif [[ -n "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE" && "$OPENJDK_SOURCE_URL_SET" -eq 1 ]]; then
  die "--loongarch64-openjdk-srpm-archive and --openjdk-source-url are mutually exclusive"
elif [[ -z "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE" && -z "$LOONGARCH64_OPENJDK_SRPM_URL" ]]; then
  OPENJDK_SOURCE_URL="$LOONGARCH64_OPENJDK_SOURCE_URL"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="openjdk-${OPENJDK_VERSION}-${PACKAGE_TRIPLE}"
fi

for archive_var in X64_JDK_ARCHIVE AARCH64_JDK_ARCHIVE MINGW64_JDK_ARCHIVE FONTCONFIG_ARCHIVE OPENJDK_ARCHIVE LOONGARCH64_OPENJDK_SRPM_ARCHIVE BOOT_JDK_ARCHIVE ZIP_ARCHIVE MAVEN_ARCHIVE; do
  archive_value="${!archive_var}"
  if [[ -n "$archive_value" ]]; then
    [[ -f "$archive_value" ]] || die "${archive_var} not found: ${archive_value}"
    printf -v "$archive_var" '%s/%s' "$(cd "$(dirname "$archive_value")" && pwd)" "$(basename "$archive_value")"
  fi
done
if [[ -n "$LOONGARCH64_OPENJDK_PATCH" ]]; then
  [[ -f "$LOONGARCH64_OPENJDK_PATCH" ]] || die "LOONGARCH64_OPENJDK_PATCH not found: ${LOONGARCH64_OPENJDK_PATCH}"
  LOONGARCH64_OPENJDK_PATCH="$(cd "$(dirname "$LOONGARCH64_OPENJDK_PATCH")" && pwd)/$(basename "$LOONGARCH64_OPENJDK_PATCH")"
fi
if [[ -n "$FONTCONFIG_DIR" ]]; then
  [[ -d "$FONTCONFIG_DIR" ]] || die "FONTCONFIG_DIR not found: ${FONTCONFIG_DIR}"
  FONTCONFIG_DIR="$(cd "$FONTCONFIG_DIR" && pwd)"
fi

if [[ -n "$FONTCONFIG_ARCHIVE" && -n "$FONTCONFIG_DIR" ]]; then
  die "--fontconfig-archive and --fontconfig-dir are mutually exclusive"
fi

require_command docker
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
DEPS_BASE="${PACKAGE_ROOT}/deps"
FONTCONFIG_PREFIX="${DEPS_BASE}/fontconfig-${PACKAGE_TRIPLE}"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

[[ -f "${MOUNT_ROOT}/container_openjdk.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_openjdk.sh"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR" "$DEPS_BASE"
make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning OpenJDK target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$FONTCONFIG_PREFIX" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "${TARGET_KIND}:${ARCH}" == "linux:riscv64" || "${TARGET_KIND}:${ARCH}" == "linux:loongarch64" ]]; then
  if [[ -z "$FONTCONFIG_ARCHIVE" && -z "$FONTCONFIG_DIR" ]]; then
    FONTCONFIG_ARCHIVE="$(find_local_fontconfig_archive || true)"
    if [[ -z "$FONTCONFIG_ARCHIVE" ]]; then
      FONTCONFIG_ARCHIVE="$(download_fontconfig_archive)"
    fi
  fi

  copy_or_extract_prefix "$FONTCONFIG_PREFIX" "$FONTCONFIG_ARCHIVE" "$FONTCONFIG_DIR" \
    "README.fontconfig" \
    "${FONTCONFIG_ASSET_PREFIX}-${PACKAGE_TRIPLE}" \
    "fontconfig-${PACKAGE_TRIPLE}" \
    "$PACKAGE_NAME"
  validate_fontconfig_prefix "$FONTCONFIG_PREFIX"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- OpenJDK build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- openjdk version: ${OPENJDK_VERSION}"
if [[ -n "$OPENJDK_ARCHIVE" ]]; then
  echo "-- openjdk archive: ${OPENJDK_ARCHIVE}"
elif [[ -n "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE" ]]; then
  echo "-- openjdk srpm archive: ${LOONGARCH64_OPENJDK_SRPM_ARCHIVE}"
elif [[ -n "$LOONGARCH64_OPENJDK_SRPM_URL" ]]; then
  echo "-- openjdk srpm source: ${LOONGARCH64_OPENJDK_SRPM_URL}"
else
  echo "-- openjdk source: ${OPENJDK_SOURCE_URL}"
fi
echo "-- maven version: ${MAVEN_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -d "$FONTCONFIG_PREFIX" ]]; then
  echo "-- fontconfig dependency: ${FONTCONFIG_PREFIX}"
fi

docker_args=(
  run --rm
  --platform linux/amd64
  -v "${SHELL_TOOLS_DIR}:/work/shell_tools:ro"
  -v "${MOUNT_ROOT}:/work/mount_root:ro"
  -v "${CACHE_DIR}:/work/cache"
  -v "${BUILD_DIR}:/work/build"
  -v "${OUT_DIR}:/opt/${PACKAGE_NAME}"
  --workdir /work
  -e "ARCH=${ARCH}"
  -e "TARGET_KIND=${TARGET_KIND}"
  -e "TARGET_TRIPLE=${TARGET_TRIPLE}"
  -e "LLVM_VERSION=${LLVM_VERSION}"
  -e "OPENJDK_VERSION=${OPENJDK_VERSION}"
  -e "MAVEN_VERSION=${MAVEN_VERSION}"
  -e "X64_JDK_URL=${X64_JDK_URL}"
  -e "AARCH64_JDK_URL=${AARCH64_JDK_URL}"
  -e "MINGW64_JDK_URL=${MINGW64_JDK_URL}"
  -e "OPENJDK_SOURCE_URL=${OPENJDK_SOURCE_URL}"
  -e "LOONGARCH64_OPENJDK_SRPM_URL=${LOONGARCH64_OPENJDK_SRPM_URL}"
  -e "BOOT_JDK_URL=${BOOT_JDK_URL}"
  -e "ZIP_URL=${ZIP_URL}"
  -e "MAVEN_URL=${MAVEN_URL}"
  -e "JOBS=${JOBS}"
  -e "SDK_PREFIX=/opt/${PACKAGE_NAME}"
)
[[ -n "${HEADLESS_BUILD_MODULES:-}" ]] && docker_args+=(-e "HEADLESS_BUILD_MODULES=${HEADLESS_BUILD_MODULES}")
[[ -n "${HEADLESS_RUNTIME_MODULES:-}" ]] && docker_args+=(-e "HEADLESS_RUNTIME_MODULES=${HEADLESS_RUNTIME_MODULES}")
[[ -n "${REQUIRE_JAVAC:-}" ]] && docker_args+=(-e "REQUIRE_JAVAC=${REQUIRE_JAVAC}")
if [[ -d "$FONTCONFIG_PREFIX" ]]; then
  docker_args+=(-v "${FONTCONFIG_PREFIX}:/work/fontconfig:ro" -e "FONTCONFIG_PREFIX=/work/fontconfig")
fi
[[ -n "$X64_JDK_ARCHIVE" ]] && docker_args+=(-v "${X64_JDK_ARCHIVE}:/work/input/x64-jdk-archive:ro" -e "X64_JDK_ARCHIVE=/work/input/x64-jdk-archive")
[[ -n "$AARCH64_JDK_ARCHIVE" ]] && docker_args+=(-v "${AARCH64_JDK_ARCHIVE}:/work/input/aarch64-jdk-archive:ro" -e "AARCH64_JDK_ARCHIVE=/work/input/aarch64-jdk-archive")
[[ -n "$MINGW64_JDK_ARCHIVE" ]] && docker_args+=(-v "${MINGW64_JDK_ARCHIVE}:/work/input/mingw64-jdk-archive:ro" -e "MINGW64_JDK_ARCHIVE=/work/input/mingw64-jdk-archive")
[[ -n "$OPENJDK_ARCHIVE" ]] && docker_args+=(-v "${OPENJDK_ARCHIVE}:/work/input/openjdk-source:ro" -e "OPENJDK_ARCHIVE=/work/input/openjdk-source")
[[ -n "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE" ]] && docker_args+=(-v "${LOONGARCH64_OPENJDK_SRPM_ARCHIVE}:/work/input/loongarch64-openjdk.src.rpm:ro" -e "LOONGARCH64_OPENJDK_SRPM_ARCHIVE=/work/input/loongarch64-openjdk.src.rpm")
[[ -n "$LOONGARCH64_OPENJDK_PATCH" ]] && docker_args+=(-v "${LOONGARCH64_OPENJDK_PATCH}:/work/input/loongarch64-openjdk.patch:ro" -e "LOONGARCH64_OPENJDK_PATCH=/work/input/loongarch64-openjdk.patch")
[[ -n "$BOOT_JDK_ARCHIVE" ]] && docker_args+=(-v "${BOOT_JDK_ARCHIVE}:/work/input/boot-jdk:ro" -e "BOOT_JDK_ARCHIVE=/work/input/boot-jdk")
[[ -n "$ZIP_ARCHIVE" ]] && docker_args+=(-v "${ZIP_ARCHIVE}:/work/input/zip-source:ro" -e "ZIP_ARCHIVE=/work/input/zip-source")
[[ -n "$MAVEN_ARCHIVE" ]] && docker_args+=(-v "${MAVEN_ARCHIVE}:/work/input/maven.zip:ro" -e "MAVEN_ARCHIVE=/work/input/maven.zip")
docker_args+=(
  "$BUILD_IMAGE"
  /bin/bash /work/mount_root/container_openjdk.sh
)

docker "${docker_args[@]}"

make_host_writable "$BUILD_DIR"
make_host_writable "$OUT_DIR"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"
chmod 644 "$ARCHIVE_PATH"

echo "-- OpenJDK archive ready: ${ARCHIVE_PATH}"
