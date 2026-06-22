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
  --openjdk-version=<ver>       OpenJDK version (default: 25.0.3)
  --maven-version=<ver>         Maven version copied into the package (default: 3.9.16)
  --llvm-version=<ver>          LLVM toolchain version for source builds (default: 18.1.8)
  --x64-jdk-url=<url>           x86_64 Linux prebuilt JDK archive URL
  --x64-jdk-archive=<archive>   Use local x86_64 Linux prebuilt JDK archive
  --aarch64-jdk-url=<url>       aarch64 Linux prebuilt JDK archive URL
  --aarch64-jdk-archive=<tar>   Use local aarch64 Linux prebuilt JDK archive
  --mingw64-jdk-url=<url>       x86_64 Windows prebuilt JDK archive URL
  --mingw64-jdk-archive=<zip>   Use local x86_64 Windows prebuilt JDK archive
  --openjdk-source-url=<url>    Source archive URL for cross source builds
  --openjdk-archive=<tar>       Use local OpenJDK source archive
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

TARGET=""
OPENJDK_VERSION="25.0.3"
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
OPENJDK_SOURCE_URL="https://openjdk-sources.osci.io/openjdk25/openjdk-25.0.3-ga.tar.xz"
OPENJDK_ARCHIVE=""
BOOT_JDK_URL="https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse"
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
    --openjdk-version=*|--jdk-version=*) OPENJDK_VERSION="${1#*=}" ;;
    --openjdk-version|--jdk-version)
      shift
      [[ $# -gt 0 ]] || die "--openjdk-version requires a value"
      OPENJDK_VERSION="$1"
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
    --openjdk-source-url=*|--jdk-source-url=*) OPENJDK_SOURCE_URL="${1#*=}" ;;
    --openjdk-source-url|--jdk-source-url)
      shift
      [[ $# -gt 0 ]] || die "--openjdk-source-url requires a value"
      OPENJDK_SOURCE_URL="$1"
      ;;
    --openjdk-archive=*|--jdk-archive=*) OPENJDK_ARCHIVE="${1#*=}" ;;
    --openjdk-archive|--jdk-archive)
      shift
      [[ $# -gt 0 ]] || die "--openjdk-archive requires a value"
      OPENJDK_ARCHIVE="$1"
      ;;
    --boot-jdk-url=*) BOOT_JDK_URL="${1#*=}" ;;
    --boot-jdk-url)
      shift
      [[ $# -gt 0 ]] || die "--boot-jdk-url requires a value"
      BOOT_JDK_URL="$1"
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

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="openjdk-${OPENJDK_VERSION}-${PACKAGE_TRIPLE}"
fi

for archive_var in X64_JDK_ARCHIVE AARCH64_JDK_ARCHIVE MINGW64_JDK_ARCHIVE OPENJDK_ARCHIVE BOOT_JDK_ARCHIVE ZIP_ARCHIVE MAVEN_ARCHIVE; do
  archive_value="${!archive_var}"
  if [[ -n "$archive_value" ]]; then
    [[ -f "$archive_value" ]] || die "${archive_var} not found: ${archive_value}"
    printf -v "$archive_var" '%s/%s' "$(cd "$(dirname "$archive_value")" && pwd)" "$(basename "$archive_value")"
  fi
done

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

[[ -f "${MOUNT_ROOT}/container_openjdk.sh" ]] || die "missing container script: ${MOUNT_ROOT}/container_openjdk.sh"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR" "$DIST_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning OpenJDK target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  docker pull --platform linux/amd64 "$BUILD_IMAGE"
fi

echo "-- OpenJDK build"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- openjdk version: ${OPENJDK_VERSION}"
echo "-- maven version: ${MAVEN_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"

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
  -e "BOOT_JDK_URL=${BOOT_JDK_URL}"
  -e "ZIP_URL=${ZIP_URL}"
  -e "MAVEN_URL=${MAVEN_URL}"
  -e "JOBS=${JOBS}"
  -e "SDK_PREFIX=/opt/${PACKAGE_NAME}"
)
[[ -n "$X64_JDK_ARCHIVE" ]] && docker_args+=(-v "${X64_JDK_ARCHIVE}:/work/input/x64-jdk-archive:ro" -e "X64_JDK_ARCHIVE=/work/input/x64-jdk-archive")
[[ -n "$AARCH64_JDK_ARCHIVE" ]] && docker_args+=(-v "${AARCH64_JDK_ARCHIVE}:/work/input/aarch64-jdk-archive:ro" -e "AARCH64_JDK_ARCHIVE=/work/input/aarch64-jdk-archive")
[[ -n "$MINGW64_JDK_ARCHIVE" ]] && docker_args+=(-v "${MINGW64_JDK_ARCHIVE}:/work/input/mingw64-jdk-archive:ro" -e "MINGW64_JDK_ARCHIVE=/work/input/mingw64-jdk-archive")
[[ -n "$OPENJDK_ARCHIVE" ]] && docker_args+=(-v "${OPENJDK_ARCHIVE}:/work/input/openjdk-source:ro" -e "OPENJDK_ARCHIVE=/work/input/openjdk-source")
[[ -n "$BOOT_JDK_ARCHIVE" ]] && docker_args+=(-v "${BOOT_JDK_ARCHIVE}:/work/input/boot-jdk:ro" -e "BOOT_JDK_ARCHIVE=/work/input/boot-jdk")
[[ -n "$ZIP_ARCHIVE" ]] && docker_args+=(-v "${ZIP_ARCHIVE}:/work/input/zip-source:ro" -e "ZIP_ARCHIVE=/work/input/zip-source")
[[ -n "$MAVEN_ARCHIVE" ]] && docker_args+=(-v "${MAVEN_ARCHIVE}:/work/input/maven.zip:ro" -e "MAVEN_ARCHIVE=/work/input/maven.zip")
docker_args+=(
  "$BUILD_IMAGE"
  /bin/bash /work/mount_root/container_openjdk.sh
)

docker "${docker_args[@]}"

make_host_writable "$PACKAGE_ROOT"
normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- OpenJDK archive ready: ${ARCHIVE_PATH}"
