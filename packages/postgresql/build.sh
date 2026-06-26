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
  ./packages/postgresql/build.sh --target=<target> [options]

Targets:
  x86_64, aarch64, riscv64, loongarch64
  x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
  riscv64-unknown-linux-gnu, loongarch64-unknown-linux-gnu
  mingw64, windows, x86_64-w64-windows-gnu

Options:
  --target=<target>                   PostgreSQL target
  --arch=<target>                     Alias for --target
  --postgresql-version=<ver>          PostgreSQL version (default: 18.4)
  --llvm-version=<ver>                Bootstrap LLVM toolchain version (default: 18.1.8)
  --llvmsdk-archive=<tar>             Target LLVM SDK archive used for PostgreSQL LLVM/JIT
  --llvmsdk-dir=<dir>                 Already extracted target LLVM SDK prefix
  --postgresql-deps-archive=<tar>     postgresql_dependencies archive to use as base prefix
  --postgresql-deps-dir=<dir>         Already extracted postgresql_dependencies prefix
  --postgresql-archive=<tar>          Use a local PostgreSQL source archive
  --postgresql-target-runner=<cmd>    Command inside the container used to run target binaries
  --qemu-binary=<path>                Host qemu-user binary to mount for foreign Linux targets
  --container-runtime=<name>          Container runtime to use (default: auto-detect podman, then docker)
  --image=<image>                     Build image for every target
                                      (default: ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8)
  --jobs=<n>                          Parallel build jobs inside container (default: 4)
  --package-name=<name>               Override the top-level directory and tarball stem
  --pull                              Pull the selected build image before building
  --clean                             Remove this target's build and output directories first
  -h, --help                          Show this help

Outputs:
  packages/postgresql/build/dist/postgresql-<version>-<triple>.tar.xz
EOF
}

find_host_wine_binary() {
  local candidate=""

  if command -v wine64 >/dev/null 2>&1; then
    command -v wine64
    return 0
  fi
  if command -v wine64-stable >/dev/null 2>&1; then
    command -v wine64-stable
    return 0
  fi
  for candidate in \
      /usr/lib/wine/wine64 \
      /usr/lib/x86_64-linux-gnu/wine/wine64 \
      /usr/lib64/wine/wine64 \
      /usr/lib/wine/wine \
      /usr/lib/x86_64-linux-gnu/wine/wine \
      /usr/lib64/wine/wine; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v wine >/dev/null 2>&1; then
    command -v wine
    return 0
  fi

  return 1
}

wine_windows_path_from_unix() {
  local unix_path="$1"

  printf 'Z:%s\n' "${unix_path//\//\\}"
}

finalize_mingw_timezone_data() {
  local host_zic="${BUILD_DIR}/postgresql-build/src/timezone/zic-host"
  local wine_binary=""
  local wine_prefix="${BUILD_DIR}/host-wineprefix"
  local zic_exe="${BUILD_DIR}/postgresql-build/src/timezone/zic.exe"
  local tzdata_zi="${BUILD_DIR}/postgresql-source/src/timezone/data/tzdata.zi"
  local timezone_dir="${OUT_DIR}/share/timezone"
  local zic_exe_win=""
  local tzdata_zi_win=""
  local timezone_dir_win=""

  [[ -f "$tzdata_zi" ]] || die "missing PostgreSQL tzdata source: ${tzdata_zi}"

  rm -rf "$timezone_dir"
  mkdir -p "$timezone_dir" "$wine_prefix"

  if [[ -x "$host_zic" ]]; then
    echo "-- compiling PostgreSQL timezone data with native host zic: ${host_zic}"
    "$host_zic" -d "$timezone_dir" "$tzdata_zi"
  else
    wine_binary="$(find_host_wine_binary)" \
      || die "native zic-host or wine64/wine is required on the host to package PostgreSQL timezone data for ${TARGET_TRIPLE}"
    [[ -f "$zic_exe" ]] || die "missing mingw zic.exe: ${zic_exe}"

    echo "-- compiling PostgreSQL timezone data with host wine: ${wine_binary}"
  zic_exe_win="$(wine_windows_path_from_unix "$zic_exe")"
  tzdata_zi_win="$(wine_windows_path_from_unix "$tzdata_zi")"
  timezone_dir_win="$(wine_windows_path_from_unix "$timezone_dir")"

    WINEARCH=win64 WINEPREFIX="$wine_prefix" WINEDEBUG=-all \
      "$wine_binary" "$zic_exe_win" -d "$timezone_dir_win" "$tzdata_zi_win"
  fi

  [[ -d "${timezone_dir}/Etc" ]] || [[ -f "${timezone_dir}/UTC" ]] \
    || die "timezone packaging did not produce expected files under ${timezone_dir}"
}

find_local_postgresql_deps_archive() {
  local archive_name=""
  local archive_path=""
  local search_dir=""

  for archive_name in \
      "postgresql_dependencies-${PACKAGE_TRIPLE}.tar.xz" \
      "postgresql_dependencies-18-${PACKAGE_TRIPLE}.tar.xz"; do
    archive_path="${PROJECT_ROOT}/packages/postgresql_dependencies/build/dist/${archive_name}"
    if [[ -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi
  done

  for search_dir in "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/cache"; do
    archive_path="$(
      find "$search_dir" \
        -type f \
        \( -name "postgresql_dependencies-${PACKAGE_TRIPLE}.tar.xz" \
           -o -name "postgresql_dependencies-18-${PACKAGE_TRIPLE}.tar.xz" \) \
        2>/dev/null \
        | sort -r \
        | head -n 1
    )"
    if [[ -n "$archive_path" && -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi
  done

  return 1
}

find_local_llvmsdk_archive() {
  local archive_path=""
  local search_dir=""

  for search_dir in "${PROJECT_ROOT}/packages/llvm/build/dist" "$INPUT_DIR" "${PROJECT_ROOT}/cache"; do
    [[ -d "$search_dir" ]] || continue
    archive_path="$(
      find "$search_dir" \
        -type f \
        -name "llvmsdk-${LLVM_VERSION}-${PACKAGE_TRIPLE}.tar.xz" \
        2>/dev/null \
        | sort -rV \
        | head -n 1
    )"
    if [[ -n "$archive_path" && -f "$archive_path" ]]; then
      printf '%s\n' "$archive_path"
      return 0
    fi
  done

  return 1
}

prepare_llvmsdk_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local tmp_extract="${output_dir}.extract"
  local extracted_dir=""

  rm -rf "$output_dir" "$tmp_extract"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "llvmsdk directory not found: ${dir_path}"
    mkdir -p "$output_dir"
    cp -a "${dir_path}/." "$output_dir/"
  elif [[ -n "$archive_path" ]]; then
    [[ -f "$archive_path" ]] || die "llvmsdk archive not found: ${archive_path}"
    mkdir -p "$tmp_extract"
    tar -xf "$archive_path" -C "$tmp_extract"
    extracted_dir="$(
      find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d -print \
        | sort \
        | head -n 1
    )"
    [[ -n "$extracted_dir" && -d "$extracted_dir" ]] \
      || die "could not find llvmsdk prefix in archive: ${archive_path}"
    mkdir -p "$output_dir"
    cp -a "${extracted_dir}/." "$output_dir/"
    rm -rf "$tmp_extract"
  else
    return 0
  fi

  [[ -d "${output_dir}/include/llvm" ]] || die "llvmsdk missing LLVM headers: ${output_dir}/include/llvm"
  find "${output_dir}/lib" -maxdepth 1 -name 'libLLVM.so*' -print -quit | grep -q . \
    || die "llvmsdk missing libLLVM shared library: ${output_dir}/lib"
}

copy_or_extract_base_prefix() {
  local output_dir="$1"
  local archive_path="$2"
  local dir_path="$3"
  local tmp_extract="${output_dir}.base-extract"
  local extracted_dir=""

  rm -rf "$output_dir" "$tmp_extract"
  mkdir -p "$output_dir"

  if [[ -n "$dir_path" ]]; then
    [[ -d "$dir_path" ]] || die "postgresql_dependencies directory not found: ${dir_path}"
    cp -a "${dir_path}/." "$output_dir/"
  else
    [[ -f "$archive_path" ]] || die "postgresql_dependencies archive not found: ${archive_path}"
    mkdir -p "$tmp_extract"
    tar -xf "$archive_path" -C "$tmp_extract"
    extracted_dir="$(
      find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d -print \
        | sort \
        | head -n 1
    )"
    if [[ -z "$extracted_dir" ]]; then
      if [[ -f "${tmp_extract}/README.postgresql-dependencies" ]]; then
        extracted_dir="$tmp_extract"
      else
        die "could not find postgresql_dependencies prefix in archive: ${archive_path}"
      fi
    fi
    cp -a "${extracted_dir}/." "$output_dir/"
    rm -rf "$tmp_extract"
  fi
}

overlay_prefix_from_archive() {
  local output_dir="$1"
  local archive_path="$2"
  local tmp_extract="${output_dir}.overlay-extract"
  local extracted_dir=""

  [[ -f "$archive_path" ]] || die "prefix overlay archive not found: ${archive_path}"

  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  tar -xf "$archive_path" -C "$tmp_extract"
  extracted_dir="$(
    find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d -print \
      | sort \
      | head -n 1
  )"
  if [[ -z "$extracted_dir" ]]; then
    die "could not find extracted prefix directory in archive: ${archive_path}"
  fi

  cp -a "${extracted_dir}/." "$output_dir/"
  rm -rf "$tmp_extract"
}

overlay_prefix_from_dir() {
  local output_dir="$1"
  local dir_path="$2"

  [[ -d "$dir_path" ]] || die "prefix overlay directory not found: ${dir_path}"
  cp -a "${dir_path}/." "$output_dir/"
}

find_optional_runtime_dir() {
  local package_name="$1"
  local dir_path=""

  dir_path="$(
    find "${PROJECT_ROOT}/packages/${package_name}/build/out" \
      -maxdepth 1 \
      -mindepth 1 \
      -type d \
      -name "${package_name}-*-${PACKAGE_TRIPLE}" \
      2>/dev/null \
      | sort -rV \
      | head -n 1
  )"

  [[ -n "$dir_path" && -d "$dir_path" ]] || return 1
  printf '%s\n' "$dir_path"
}

find_optional_runtime_archive() {
  local package_name="$1"
  local archive_path=""

  archive_path="$(
    find "${PROJECT_ROOT}/packages/${package_name}/build/dist" \
      -maxdepth 1 \
      -type f \
      -name "${package_name}-*-${PACKAGE_TRIPLE}.tar.xz" \
      2>/dev/null \
      | sort -rV \
      | head -n 1
  )"

  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    printf '%s\n' "$archive_path"
    return 0
  fi

  archive_path="$(
    find "$INPUT_DIR" -maxdepth 1 -type f -name "${package_name}-*-${PACKAGE_TRIPLE}.tar.xz" \
      | sort -rV \
      | head -n 1
  )"

  [[ -n "$archive_path" && -f "$archive_path" ]] || return 1
  printf '%s\n' "$archive_path"
}

overlay_optional_runtime_archives() {
  local runtime_name=""
  local dir_path=""
  local archive_path=""

  for runtime_name in python perl tcl; do
    dir_path="$(find_optional_runtime_dir "$runtime_name" || true)"
    if [[ -n "$dir_path" ]]; then
      echo "-- overlaying optional runtime directory: ${dir_path}"
      overlay_prefix_from_dir "$OUT_DIR" "$dir_path"
      continue
    fi

    archive_path="$(find_optional_runtime_archive "$runtime_name" || true)"
    if [[ -n "$archive_path" ]]; then
      echo "-- overlaying optional runtime archive: ${archive_path}"
      overlay_prefix_from_archive "$OUT_DIR" "$archive_path"
    fi
  done
}

validate_base_prefix() {
  local dir="$1"

  [[ -d "$dir" ]] || die "base prefix not found: ${dir}"
  [[ -f "${dir}/README.postgresql-dependencies" ]] || die "missing postgresql_dependencies marker: ${dir}/README.postgresql-dependencies"
  [[ -d "${dir}/include" ]] || die "missing base include directory: ${dir}/include"
  [[ -d "${dir}/lib" ]] || die "missing base lib directory: ${dir}/lib"
}

TARGET=""
POSTGRESQL_VERSION="18.4"
LLVM_VERSION="18.1.8"
BUILD_IMAGE="$PACKAGES_DEFAULT_BUILD_IMAGE"
JOBS="$PACKAGES_DEFAULT_JOBS"
PACKAGE_NAME=""
LLVMSDK_ARCHIVE=""
LLVMSDK_DIR=""
POSTGRESQL_DEPS_ARCHIVE=""
POSTGRESQL_DEPS_DIR=""
POSTGRESQL_ARCHIVE=""
POSTGRESQL_TARGET_RUNNER=""
QEMU_BINARY=""
CONTAINER_RUNTIME=""
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
    --postgresql-version=*) POSTGRESQL_VERSION="${1#*=}" ;;
    --postgresql-version)
      shift
      [[ $# -gt 0 ]] || die "--postgresql-version requires a value"
      POSTGRESQL_VERSION="$1"
      ;;
    --llvm-version=*) LLVM_VERSION="${1#*=}" ;;
    --llvm-version)
      shift
      [[ $# -gt 0 ]] || die "--llvm-version requires a value"
      LLVM_VERSION="$1"
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
    --postgresql-deps-archive=*|--dependency-archive=*) POSTGRESQL_DEPS_ARCHIVE="${1#*=}" ;;
    --postgresql-deps-archive|--dependency-archive)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      POSTGRESQL_DEPS_ARCHIVE="$1"
      ;;
    --postgresql-deps-dir=*|--dependency-dir=*) POSTGRESQL_DEPS_DIR="${1#*=}" ;;
    --postgresql-deps-dir|--dependency-dir)
      opt="$1"
      shift
      [[ $# -gt 0 ]] || die "${opt} requires a value"
      POSTGRESQL_DEPS_DIR="$1"
      ;;
    --postgresql-archive=*) POSTGRESQL_ARCHIVE="${1#*=}" ;;
    --postgresql-archive)
      shift
      [[ $# -gt 0 ]] || die "--postgresql-archive requires a value"
      POSTGRESQL_ARCHIVE="$1"
      ;;
    --postgresql-target-runner=*) POSTGRESQL_TARGET_RUNNER="${1#*=}" ;;
    --postgresql-target-runner)
      shift
      [[ $# -gt 0 ]] || die "--postgresql-target-runner requires a value"
      POSTGRESQL_TARGET_RUNNER="$1"
      ;;
    --qemu-binary=*) QEMU_BINARY="${1#*=}" ;;
    --qemu-binary)
      shift
      [[ $# -gt 0 ]] || die "--qemu-binary requires a value"
      QEMU_BINARY="$1"
      ;;
    --container-runtime=*) CONTAINER_RUNTIME="${1#*=}" ;;
    --container-runtime)
      shift
      [[ $# -gt 0 ]] || die "--container-runtime requires a value"
      CONTAINER_RUNTIME="$1"
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
resolve_target "$TARGET" "PostgreSQL target"

if [[ -n "$POSTGRESQL_DEPS_ARCHIVE" && -n "$POSTGRESQL_DEPS_DIR" ]]; then
  die "--postgresql-deps-archive and --postgresql-deps-dir are mutually exclusive"
fi

if [[ -n "$LLVMSDK_ARCHIVE" && -n "$LLVMSDK_DIR" ]]; then
  die "--llvmsdk-archive and --llvmsdk-dir are mutually exclusive"
fi

if [[ -n "$QEMU_BINARY" && -n "$POSTGRESQL_TARGET_RUNNER" ]]; then
  die "--qemu-binary and --postgresql-target-runner are mutually exclusive"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  PACKAGE_NAME="postgresql-${POSTGRESQL_VERSION}-${PACKAGE_TRIPLE}"
fi

if [[ -z "$POSTGRESQL_DEPS_ARCHIVE" && -z "$POSTGRESQL_DEPS_DIR" ]]; then
  POSTGRESQL_DEPS_ARCHIVE="$(find_local_postgresql_deps_archive)" \
    || die "postgresql_dependencies archive not provided and no local archive was found for ${PACKAGE_TRIPLE}"
fi

if [[ -n "$POSTGRESQL_ARCHIVE" ]]; then
  [[ -f "$POSTGRESQL_ARCHIVE" ]] || die "PostgreSQL source archive not found: ${POSTGRESQL_ARCHIVE}"
  POSTGRESQL_ARCHIVE="$(cd "$(dirname "$POSTGRESQL_ARCHIVE")" && pwd)/$(basename "$POSTGRESQL_ARCHIVE")"
fi

if [[ -n "$LLVMSDK_ARCHIVE" ]]; then
  [[ -f "$LLVMSDK_ARCHIVE" ]] || die "LLVM SDK archive not found: ${LLVMSDK_ARCHIVE}"
  LLVMSDK_ARCHIVE="$(cd "$(dirname "$LLVMSDK_ARCHIVE")" && pwd)/$(basename "$LLVMSDK_ARCHIVE")"
fi

if [[ -n "$LLVMSDK_DIR" ]]; then
  [[ -d "$LLVMSDK_DIR" ]] || die "LLVM SDK directory not found: ${LLVMSDK_DIR}"
  LLVMSDK_DIR="$(cd "$LLVMSDK_DIR" && pwd)"
fi

QEMU_BINARY_CONTAINER_PATH=""
if [[ -n "$QEMU_BINARY" ]]; then
  [[ -f "$QEMU_BINARY" ]] || die "qemu binary not found: ${QEMU_BINARY}"
  [[ -x "$QEMU_BINARY" ]] || die "qemu binary is not executable: ${QEMU_BINARY}"
  QEMU_BINARY="$(cd "$(dirname "$QEMU_BINARY")" && pwd)/$(basename "$QEMU_BINARY")"
fi

if [[ -z "$POSTGRESQL_TARGET_RUNNER" && "$TARGET_KIND" == "linux" && "$ARCH" != "x86_64" ]]; then
  if [[ -z "$QEMU_BINARY" ]]; then
    QEMU_BINARY="$(find_host_qemu_user_binary "$ARCH" || true)"
  fi

  if [[ -n "$QEMU_BINARY" ]]; then
    QEMU_BINARY_CONTAINER_PATH="/work/qemu/$(basename "$QEMU_BINARY")"
    POSTGRESQL_TARGET_RUNNER="env QEMU_LD_PREFIX=/opt/sysroot/${TARGET_TRIPLE} ${QEMU_BINARY_CONTAINER_PATH} -L /opt/sysroot/${TARGET_TRIPLE}"
  else
    qemu_hint="$(target_qemu_user_binary_names "$ARCH" 2>/dev/null | paste -sd ' / ' - || true)"
    die "no default qemu runner found for ${TARGET_TRIPLE}; install qemu-user so one of [${qemu_hint:-qemu-aarch64/qemu-loongarch64/qemu-riscv64}] exists, or pass --qemu-binary / --postgresql-target-runner"
  fi
fi

CONTAINER_RUNTIME="$(resolve_container_runtime "$CONTAINER_RUNTIME")"
require_command tar

MOUNT_ROOT="${ROOT_DIR}/mount_root"
CACHE_DIR="${PROJECT_ROOT}/cache"
PACKAGE_ROOT="${ROOT_DIR}/build"
BUILD_DIR="${PACKAGE_ROOT}/work/${TARGET_TRIPLE}"
LLVMSDK_EXTRACT_DIR="${BUILD_DIR}/llvmsdk"
OUT_BASE="${PACKAGE_ROOT}/out"
OUT_DIR="${OUT_BASE}/${PACKAGE_NAME}"
DIST_DIR="${PACKAGE_ROOT}/dist"
INPUT_DIR="${PACKAGE_ROOT}/inputs"
ARCHIVE_PATH="${DIST_DIR}/${PACKAGE_NAME}.tar.xz"

case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64)
    CONTAINER_SCRIPT="${MOUNT_ROOT}/container_linux_native.sh"
    ;;
  linux:*)
    CONTAINER_SCRIPT="${MOUNT_ROOT}/container_linux_cross.sh"
    ;;
  mingw:x86_64)
    CONTAINER_SCRIPT="${MOUNT_ROOT}/container_mingw64.sh"
    ;;
  *)
    die "packages/postgresql does not support target ${TARGET_KIND}:${ARCH}"
    ;;
esac
[[ -f "$CONTAINER_SCRIPT" ]] || die "missing container script: ${CONTAINER_SCRIPT}"

make_host_writable "$PACKAGE_ROOT"
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_BASE" "$DIST_DIR" "$INPUT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
  echo "-- cleaning PostgreSQL target: ${TARGET_TRIPLE}"
  rm -rf "$BUILD_DIR" "$OUT_DIR" "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"
fi

copy_or_extract_base_prefix "$OUT_DIR" "$POSTGRESQL_DEPS_ARCHIVE" "$POSTGRESQL_DEPS_DIR"
overlay_optional_runtime_archives
validate_base_prefix "$OUT_DIR"

if [[ "$TARGET_KIND" == "linux" && -z "$LLVMSDK_ARCHIVE" && -z "$LLVMSDK_DIR" ]]; then
  LLVMSDK_ARCHIVE="$(find_local_llvmsdk_archive || true)"
fi
if [[ "$TARGET_KIND" == "linux" ]] && [[ -n "$LLVMSDK_ARCHIVE" || -n "$LLVMSDK_DIR" ]]; then
  echo "-- preparing LLVM SDK for PostgreSQL JIT"
  prepare_llvmsdk_prefix "$LLVMSDK_EXTRACT_DIR" "$LLVMSDK_ARCHIVE" "$LLVMSDK_DIR"
fi

if [[ "$PULL" -eq 1 ]]; then
  echo "-- pulling build image: ${BUILD_IMAGE}"
  "$CONTAINER_RUNTIME" pull --platform linux/amd64 "$BUILD_IMAGE"
fi

EXTRA_MOUNTS=()
CONTAINER_POSTGRESQL_ARCHIVE=""
if [[ -n "$POSTGRESQL_ARCHIVE" ]]; then
  CONTAINER_POSTGRESQL_ARCHIVE="/work/input/$(basename "$POSTGRESQL_ARCHIVE")"
  EXTRA_MOUNTS+=(-v "$(dirname "$POSTGRESQL_ARCHIVE"):/work/input:ro")
fi

echo "-- PostgreSQL build"
echo "-- runtime: ${CONTAINER_RUNTIME}"
echo "-- image: ${BUILD_IMAGE}"
echo "-- target kind: ${TARGET_KIND}"
echo "-- target triple: ${TARGET_TRIPLE}"
echo "-- postgresql version: ${POSTGRESQL_VERSION}"
echo "-- package: ${PACKAGE_NAME}"
echo "-- output: ${OUT_DIR}"
if [[ -n "$POSTGRESQL_DEPS_ARCHIVE" ]]; then
  echo "-- base dependency archive: ${POSTGRESQL_DEPS_ARCHIVE}"
else
  echo "-- base dependency dir: ${POSTGRESQL_DEPS_DIR}"
fi
if [[ -n "$QEMU_BINARY" ]]; then
  echo "-- qemu binary: ${QEMU_BINARY}"
fi
if [[ -n "$POSTGRESQL_TARGET_RUNNER" ]]; then
  echo "-- postgresql target runner: ${POSTGRESQL_TARGET_RUNNER}"
fi
container_args=(
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
  -e "POSTGRESQL_VERSION=${POSTGRESQL_VERSION}"
  -e "POSTGRESQL_ARCHIVE=${CONTAINER_POSTGRESQL_ARCHIVE}"
  -e "POSTGRESQL_TARGET_RUNNER=${POSTGRESQL_TARGET_RUNNER}"
  -e "POSTGRESQL_LLVM_ROOT=$([[ "$TARGET_KIND" == "linux" && -d "$LLVMSDK_EXTRACT_DIR" ]] && printf /work/build/llvmsdk || true)"
  -e "JOBS=${JOBS}"
  -e "SDK_PREFIX=/opt/${PACKAGE_NAME}"
)
container_args+=("${EXTRA_MOUNTS[@]}")
if [[ -n "$QEMU_BINARY" && -n "$QEMU_BINARY_CONTAINER_PATH" ]]; then
  container_args+=(
    -v "${QEMU_BINARY}:${QEMU_BINARY_CONTAINER_PATH}:ro"
  )
fi
container_args+=(
  "$BUILD_IMAGE"
  /bin/bash /work/mount_root/$(basename "$CONTAINER_SCRIPT")
)

"$CONTAINER_RUNTIME" "${container_args[@]}"

make_host_writable "$PACKAGE_ROOT"

if [[ "$TARGET_KIND" == "mingw" ]]; then
  finalize_mingw_timezone_data
  materialize_symlinks "$OUT_DIR"
fi

normalize_package_permissions "$OUT_DIR"

rm -f "$ARCHIVE_PATH"
tar -C "$OUT_BASE" -cJf "$ARCHIVE_PATH" "$PACKAGE_NAME"

echo "-- PostgreSQL archive ready: ${ARCHIVE_PATH}"
