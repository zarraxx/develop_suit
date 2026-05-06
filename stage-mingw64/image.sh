#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./stage-mingw64/image.sh --arch=x86_64 [options]

Options:
  --arch=<arch>             Host arch: x86_64 initially
  --tag=<name>              Docker image tag, repeatable
                            (default: develop_suit:llvm-with-mingw64-18.1.8)
  --base-image=<image>      Base image
                            (default: ghcr.io/zarraxx/develop_suit:llvm-18.1.8)
  --skip-test               Skip the post-build container smoke test
  --push                    Push image directly to registry instead of writing a tar
  --output=<path>           Output Docker archive path
                            (default: <repo>/dist/images/llvm-with-mingw64-18.1.8-<arch>.tar)
  --dockerfile=<path>       Override Dockerfile path
                            (default: <repo>/stage-mingw64/Dockerfile)
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
    *)
      die "stage-mingw64 initially supports only x86_64 images: $1"
      ;;
  esac
}

docker_platform_for_arch() {
  case "$1" in
    x86_64)
      echo "linux/amd64"
      ;;
    *)
      die "no docker platform mapping for arch: $1"
      ;;
  esac
}

ARCH=""
TAGS=()
BASE_IMAGE="ghcr.io/zarraxx/develop_suit:llvm-18.1.8"
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
    --base-image=*)
      BASE_IMAGE="${1#*=}"
      ;;
    --base-image)
      shift
      [[ $# -gt 0 ]] || die "--base-image requires a value"
      BASE_IMAGE="$1"
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
MINGW_ROOTFS_DIR="${ROOT_DIR}/build/out/${ARCH}"

[[ -d "$MINGW_ROOTFS_DIR" ]] || die "stage-mingw64 output directory does not exist: $MINGW_ROOTFS_DIR"
[[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile does not exist: $DOCKERFILE_PATH"
[[ -d "$CONTEXT_PATH" ]] || die "docker build context does not exist: $CONTEXT_PATH"
[[ -f "$SMOKE_TEST_SCRIPT" ]] || die "smoke test script does not exist: $SMOKE_TEST_SCRIPT"

if [[ ${#TAGS[@]} -eq 0 ]]; then
  TAGS=("develop_suit:llvm-with-mingw64-18.1.8")
fi

if [[ "$PUSH" -eq 0 && -z "$OUTPUT" ]]; then
  OUTPUT="${PROJECT_ROOT}/dist/images/llvm-with-mingw64-18.1.8-${ARCH}.tar"
fi

buildx_help="$(docker buildx build --help 2>&1 || true)"
IS_PODMAN=0
if grep -q 'podman buildx build' <<EOF
${buildx_help}
EOF
then
  IS_PODMAN=1
fi
WROTE_ARCHIVE=0

echo "Building stage-mingw64 Docker image for arch=${ARCH} platform=${PLATFORM}"
echo "Using base image: ${BASE_IMAGE}"
echo "Using stage-mingw64 rootfs overlay: ${MINGW_ROOTFS_DIR}"
for tag in "${TAGS[@]}"; do
  echo "Using tag: ${tag}"
done

build_args=(
  buildx build
  --file "${DOCKERFILE_PATH}"
  --platform "${PLATFORM}"
  --build-arg "STAGE_MINGW64_ARCH=${ARCH}"
  --build-arg "STAGE_MINGW64_BASE_IMAGE=${BASE_IMAGE}"
)

for tag in "${TAGS[@]}"; do
  build_args+=(--tag "${tag}")
done

if [[ "$PUSH" -eq 1 ]]; then
  echo "Pushing image to registry"
  build_args+=(--push)
elif [[ "$IS_PODMAN" -eq 1 ]]; then
  echo "Podman buildx detected; keeping local image tag instead of writing a Docker archive"
else
  mkdir -p "$(dirname "$OUTPUT")"
  echo "Writing Docker archive: ${OUTPUT}"
  build_args+=(--output "type=docker,dest=${OUTPUT}")
  WROTE_ARCHIVE=1
fi

build_args+=("${CONTEXT_PATH}")

docker "${build_args[@]}"

if [[ "$PUSH" -eq 1 ]]; then
  echo "Docker image push finished"
elif [[ "$WROTE_ARCHIVE" -eq 1 ]]; then
  echo "Docker archive is ready at ${OUTPUT}"
else
  echo "Docker image is ready locally as ${TAGS[0]}"
fi

if [[ "$SKIP_TEST" -eq 0 ]]; then
  require_command file

  test_tag="${TAGS[0]}"
  smoke_output_dir="${ROOT_DIR}/build/smoke/${ARCH}"

  if [[ "$WROTE_ARCHIVE" -eq 1 ]]; then
    echo "Loading image archive for smoke test: ${OUTPUT}"
    docker load -i "${OUTPUT}"
  fi

  rm -rf "${smoke_output_dir}"
  mkdir -p "${smoke_output_dir}"

  echo "Running smoke test for image: ${test_tag}"
  docker run --rm -i \
    --platform "${PLATFORM}" \
    -v "${ROOT_DIR}:/opt/stage_mingw64:ro" \
    -v "${smoke_output_dir}:/opt/stage_mingw64_out" \
    --entrypoint /bin/sh \
    "${test_tag}" \
    /opt/stage_mingw64/smoke-test.sh /opt/stage_mingw64_out

  echo "Checking smoke test outputs on host with file"
  file "${smoke_output_dir}"/*
  echo "Smoke test finished"
fi
