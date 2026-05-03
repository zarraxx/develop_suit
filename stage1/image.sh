#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage1/image.sh --arch=<arch> [options]
  ./stage1/image.sh arch=<arch> [options]

Options:
  --arch=<arch>             Target arch: x86_64, aarch64, riscv64, loongarch64
  --tag=<name>              Docker image tag, repeatable
                            (default: stage1-rootfs:<arch>)
  --skip-test               Skip the post-build container smoke test
  --push                    Push image directly to registry instead of writing a tar
  --output=<path>           Output Docker archive path
                            (default: <repo>/dist/images/stage1-image-<arch>.tar)
  --dockerfile=<path>       Override Dockerfile path
                            (default: <repo>/stage1/Dockerfile)
  --context=<path>          Override docker build context
                            (default: <repo>)
  -h, --help                Show this help
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

ARCH=""
TAGS=()
SKIP_TEST=0
PUSH=0
OUTPUT=""
DOCKERFILE_PATH="${ROOT_DIR}/Dockerfile"
CONTEXT_PATH="${PROJECT_ROOT}"
SMOKE_TEST_SCRIPT="${ROOT_DIR}/smoke-test.sh"

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
    --tag=*)
      TAGS+=("${1#*=}")
      ;;
    --tag)
      shift
      [[ $# -gt 0 ]] || die "--tag requires a value"
      TAGS+=("$1")
      ;;
    --skip-test)
      SKIP_TEST=1
      ;;
    --push)
      PUSH=1
      ;;
    --output=*)
      OUTPUT="${1#*=}"
      ;;
    --output)
      shift
      [[ $# -gt 0 ]] || die "--output requires a value"
      OUTPUT="$1"
      ;;
    --dockerfile=*)
      DOCKERFILE_PATH="${1#*=}"
      ;;
    --dockerfile)
      shift
      [[ $# -gt 0 ]] || die "--dockerfile requires a value"
      DOCKERFILE_PATH="$1"
      ;;
    --context=*)
      CONTEXT_PATH="${1#*=}"
      ;;
    --context)
      shift
      [[ $# -gt 0 ]] || die "--context requires a value"
      CONTEXT_PATH="$1"
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

require_command docker

ARCH="$(normalize_arch "$ARCH")"
PLATFORM="$(docker_platform_for_arch "$ARCH")"
ROOTFS_DIR="${PROJECT_ROOT}/dist/stage1/${ARCH}"

[[ -d "$ROOTFS_DIR" ]] || die "stage1 rootfs directory does not exist: $ROOTFS_DIR"
[[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile does not exist: $DOCKERFILE_PATH"
[[ -d "$CONTEXT_PATH" ]] || die "docker build context does not exist: $CONTEXT_PATH"
[[ -f "$SMOKE_TEST_SCRIPT" ]] || die "smoke test script does not exist: $SMOKE_TEST_SCRIPT"

if [[ ${#TAGS[@]} -eq 0 ]]; then
  TAGS=("stage1-rootfs:${ARCH}")
fi

if [[ "$PUSH" -eq 0 && -z "$OUTPUT" ]]; then
  OUTPUT="${PROJECT_ROOT}/dist/images/stage1-image-${ARCH}.tar"
fi

echo "Building stage1 Docker image for arch=${ARCH} platform=${PLATFORM}"
echo "Using rootfs: ${ROOTFS_DIR}"
for tag in "${TAGS[@]}"; do
  echo "Using tag: ${tag}"
done

build_args=(
  buildx build
  --file "${DOCKERFILE_PATH}"
  --platform "${PLATFORM}"
  --build-arg "STAGE1_ARCH=${ARCH}"
  --provenance=false
  --sbom=false
)

for tag in "${TAGS[@]}"; do
  build_args+=(--tag "${tag}")
done

if [[ "$PUSH" -eq 1 ]]; then
  echo "Pushing image to registry"
  build_args+=(--push)
else
  mkdir -p "$(dirname "$OUTPUT")"
  echo "Writing Docker archive: ${OUTPUT}"
  build_args+=(--output "type=docker,dest=${OUTPUT}")
fi

build_args+=("${CONTEXT_PATH}")

docker "${build_args[@]}"

if [[ "$PUSH" -eq 1 ]]; then
  echo "Docker image push finished"
else
  echo "Docker archive is ready at ${OUTPUT}"
fi

if [[ "$SKIP_TEST" -eq 0 ]]; then
  test_tag="${TAGS[0]}"

  if [[ "$PUSH" -eq 0 ]]; then
    echo "Loading image archive for smoke test: ${OUTPUT}"
    docker load -i "${OUTPUT}"
  fi

  echo "Running smoke test for image: ${test_tag}"
  docker run --rm -i --platform "${PLATFORM}" --entrypoint /bin/sh "${test_tag}" < "${SMOKE_TEST_SCRIPT}"
  echo "Smoke test finished"
fi
