#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

download_archive() {
  local url="$1"
  local archive_name="$2"

  mkdir -p "$CACHE_DIR"
  if [[ ! -s "${CACHE_DIR}/${archive_name}" ]]; then
    rm -f "${CACHE_DIR:?}/${archive_name}" "${CACHE_DIR}/${archive_name}.tmp"
    log "Downloading ${archive_name}"
    curl -L --fail --retry 3 -o "${CACHE_DIR}/${archive_name}.tmp" "$url"
    mv "${CACHE_DIR}/${archive_name}.tmp" "${CACHE_DIR}/${archive_name}"
  fi
}

extract_source() {
  local source_dir="$1"
  local archive_name="$2"
  local marker_path="$3"
  local archive_marker="${source_dir}/.source-archive"

  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xf "${CACHE_DIR}/${archive_name}" -C "$source_dir" --strip-components=1
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

target_cross_cc_prefix() {
  case "$TARGET_TRIPLE" in
    x86_64-unknown-linux-gnu) printf '%s\n' "" ;;
    aarch64-unknown-linux-gnu) printf '%s\n' "aarch64-linux-gnu-" ;;
    riscv64-unknown-linux-gnu) printf '%s\n' "riscv64-linux-gnu-" ;;
    loongarch64-unknown-linux-gnu) printf '%s\n' "loongarch64-linux-gnu-" ;;
    x86_64-w64-windows-gnu) printf '%s\n' "x86_64-w64-windows-gnu-" ;;
    *) die "unsupported target triple: ${TARGET_TRIPLE}" ;;
  esac
}

write_exec_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  mkdir -p "$(dirname "$wrapper_path")"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${real_tool}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_clang="$2"
  local extra_flags="$3"

  mkdir -p "$(dirname "$wrapper_path")"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${real_clang}" --target="${TARGET_TRIPLE}" ${extra_flags} "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_windres_wrapper() {
  local wrapper_path="$1"
  local real_windres="$2"

  mkdir -p "$(dirname "$wrapper_path")"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${real_windres}" --target=pe-x86-64 -I "/opt/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/include" "\$@"
EOF
  chmod +x "$wrapper_path"
}

link_tool_alias() {
  local target_name="$1"
  local alias_path="$2"

  if [[ "$(basename "$alias_path")" == "$target_name" ]]; then
    return 0
  fi

  ln -sf "$target_name" "$alias_path"
}

prepare_build_tool_wrappers() {
  local compiler_flags=""

  rm -rf "$BUILD_TOOLS"
  mkdir -p "$BUILD_TOOLS"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    compiler_flags="--sysroot=/opt/${TARGET_TRIPLE}/sysroot -B/opt/${TARGET_TRIPLE}/bin -isystem /opt/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/include -L/opt/${TARGET_TRIPLE}/lib -L/opt/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/lib -fuse-ld=lld -Wno-unused-command-line-argument"
  else
    compiler_flags="--sysroot=/opt/sysroot/${TARGET_TRIPLE} -fuse-ld=lld -Wno-unused-command-line-argument"
  fi

  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "${LLVM_ROOT}/bin/clang" "$compiler_flags"
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx" "${LLVM_ROOT}/bin/clang++" "$compiler_flags"
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-gcc" "${LLVM_ROOT}/bin/clang" "$compiler_flags"
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-g++" "${LLVM_ROOT}/bin/clang++" "$compiler_flags"
  write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-ar" "${LLVM_ROOT}/bin/llvm-ar"
  write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-ranlib" "${LLVM_ROOT}/bin/llvm-ranlib"
  write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-nm" "${LLVM_ROOT}/bin/llvm-nm"
  write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-strip" "${LLVM_ROOT}/bin/llvm-strip"

  link_tool_alias "${TARGET_TRIPLE}-ar" "${BUILD_TOOLS}/ar"
  link_tool_alias "${TARGET_TRIPLE}-ranlib" "${BUILD_TOOLS}/ranlib"
  link_tool_alias "${TARGET_TRIPLE}-nm" "${BUILD_TOOLS}/nm"
  link_tool_alias "${TARGET_TRIPLE}-strip" "${BUILD_TOOLS}/strip"

  if [[ -n "$CROSS_PREFIX" ]]; then
    link_tool_alias "${TARGET_TRIPLE}-gcc" "${BUILD_TOOLS}/${CROSS_PREFIX}gcc"
    link_tool_alias "${TARGET_TRIPLE}-g++" "${BUILD_TOOLS}/${CROSS_PREFIX}g++"
    link_tool_alias "${TARGET_TRIPLE}-ar" "${BUILD_TOOLS}/${CROSS_PREFIX}ar"
    link_tool_alias "${TARGET_TRIPLE}-ranlib" "${BUILD_TOOLS}/${CROSS_PREFIX}ranlib"
    link_tool_alias "${TARGET_TRIPLE}-nm" "${BUILD_TOOLS}/${CROSS_PREFIX}nm"
    link_tool_alias "${TARGET_TRIPLE}-strip" "${BUILD_TOOLS}/${CROSS_PREFIX}strip"
  fi

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "${LLVM_ROOT}/bin/llvm-windres"
    link_tool_alias "${TARGET_TRIPLE}-windres" "${BUILD_TOOLS}/windres"
  fi
}

target_goos() {
  case "$TARGET_KIND" in
    linux) printf '%s\n' "linux" ;;
    mingw) printf '%s\n' "windows" ;;
    *) die "unsupported GOOS target kind: ${TARGET_KIND}" ;;
  esac
}

target_goarch() {
  case "$TARGET_TRIPLE" in
    x86_64-unknown-linux-gnu|x86_64-w64-windows-gnu) printf '%s\n' "amd64" ;;
    aarch64-unknown-linux-gnu) printf '%s\n' "arm64" ;;
    riscv64-unknown-linux-gnu) printf '%s\n' "riscv64" ;;
    loongarch64-unknown-linux-gnu) printf '%s\n' "loong64" ;;
    *) die "unsupported GOARCH for ${TARGET_TRIPLE}" ;;
  esac
}

host_env() {
  env \
    PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}" \
    CC="$CC" \
    CXX="$CXX" \
    LD="$LD" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    NM="$NM" \
    STRIP="$STRIP" \
    CFLAGS="${COMMON_CFLAGS} ${CFLAGS:-}" \
    CXXFLAGS="${COMMON_CFLAGS} ${CXXFLAGS:-}" \
    LDFLAGS="${COMMON_LDFLAGS} ${LDFLAGS:-}" \
    "$@"
}

go_env() {
  env \
    PATH="${GO_ROOT}/bin:${PATH}" \
    HOME="${BUILD_DIR}/go-home" \
    GOMODCACHE="${CACHE_DIR}/go/pkg/mod" \
    GOCACHE="${BUILD_DIR}/go/cache" \
    GOOS="$GOOS" \
    GOARCH="$GOARCH" \
    CGO_ENABLED=0 \
    GOTOOLCHAIN=local \
    GOPROXY="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}" \
    "$@"
}

retry_go() {
  local attempt=1

  while true; do
    if go_env "$@"; then
      return 0
    fi
    if [[ "$attempt" -ge 4 ]]; then
      return 1
    fi
    log "Go command failed; retrying attempt $((attempt + 1))/4: $*"
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
}

install_go_toolchain() {
  local source_dir="${BUILD_DIR}/go-toolchain"
  local archive_name="go${GO_VERSION}.linux-amd64.tar.gz"

  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  tar -xf "${CACHE_DIR}/${archive_name}" -C "$source_dir"
  GO_ROOT="${source_dir}/go"
  [[ -x "${GO_ROOT}/bin/go" ]] || die "missing Go toolchain: ${GO_ROOT}/bin/go"
}

build_redis() {
  local source_dir="${SOURCE_DIR}/redis"
  local build_dir="${BUILD_DIR}/redis-build"
  local exeext=""

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping Redis for MinGW: upstream Redis server does not support native Windows builds"
    return 0
  fi

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cp -a "${source_dir}/." "$build_dir/"

  log "Building Redis ${REDIS_VERSION}"
  (
    cd "${build_dir}/src"
    host_env make -j "$JOBS" \
      BUILD_TLS=no \
      MALLOC=libc \
      USE_SYSTEMD=no \
      CC="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      redis-server redis-cli redis-benchmark
  )

  install -d "${SDK_PREFIX}/bin"
  install -m 755 \
    "${build_dir}/src/redis-server${exeext}" \
    "${build_dir}/src/redis-cli${exeext}" \
    "${build_dir}/src/redis-benchmark${exeext}" \
    "${SDK_PREFIX}/bin/"
}

build_minio() {
  local source_dir="${SOURCE_DIR}/minio"
  local exeext=""

  [[ "$TARGET_KIND" == "mingw" ]] && exeext=".exe"

  log "Building MinIO ${MINIO_REF}"
  (
    cd "$source_dir"
    retry_go go mod download
    retry_go go build -trimpath -ldflags "-s -w" -o "${SDK_PREFIX}/bin/minio${exeext}" .
  )
}

build_etcd() {
  local source_dir="${SOURCE_DIR}/etcd"
  local exeext=""

  [[ "$TARGET_KIND" == "mingw" ]] && exeext=".exe"

  log "Building etcd ${ETCD_VERSION}"
  (
    cd "${source_dir}/server"
    retry_go go mod download
    retry_go go build -trimpath -ldflags "-s -w" -o "${SDK_PREFIX}/bin/etcd${exeext}" .
    cd "${source_dir}/etcdctl"
    retry_go go mod download
    retry_go go build -trimpath -ldflags "-s -w" -o "${SDK_PREFIX}/bin/etcdctl${exeext}" .
    cd "${source_dir}/etcdutl"
    retry_go go mod download
    retry_go go build -trimpath -ldflags "-s -w" -o "${SDK_PREFIX}/bin/etcdutl${exeext}" .
  )
}

build_patchelf() {
  local source_dir="${SOURCE_DIR}/patchelf"
  local build_dir="${BUILD_DIR}/patchelf-build"
  local patchelf_ldflags='-Wl,-rpath,\$$ORIGIN/../lib'

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Skipping patchelf for MinGW: patchelf is an ELF utility"
    return 0
  fi

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  log "Building patchelf ${PATCHELF_VERSION}"
  (
    cd "$build_dir"
    LDFLAGS="${patchelf_ldflags} ${LDFLAGS:-}" host_env "${source_dir}/configure" \
      --host="${TARGET_TRIPLE}" \
      --prefix="${SDK_PREFIX}" \
      --disable-dependency-tracking
    LDFLAGS="${patchelf_ldflags} ${LDFLAGS:-}" host_env make -j "$JOBS"
    LDFLAGS="${patchelf_ldflags} ${LDFLAGS:-}" host_env make install
  )

  install -d "${SDK_PREFIX}/lib"
  cp -a "${LLVM_ROOT}/lib/${TARGET_TRIPLE}/libc++.so"* "${SDK_PREFIX}/lib/"
  cp -a "${LLVM_ROOT}/lib/${TARGET_TRIPLE}/libc++abi.so"* "${SDK_PREFIX}/lib/"
  cp -a "${LLVM_ROOT}/lib/${TARGET_TRIPLE}/libunwind.so"* "${SDK_PREFIX}/lib/"
}

write_service_files() {
  install -d "${SDK_PREFIX}/conf"

  if [[ "$TARGET_KIND" == "linux" ]]; then
    install -m 644 /work/mount_root/templates/redis.conf.in \
      "${SDK_PREFIX}/conf/redis.conf.template"
    install -m 644 /work/mount_root/templates/minio.env.in \
      "${SDK_PREFIX}/conf/minio.env.template"
    install -m 644 /work/mount_root/templates/systemd.redis.service.in \
      "${SDK_PREFIX}/conf/systemd.redis.service.template"
    install -m 644 /work/mount_root/templates/systemd.minio.service.in \
      "${SDK_PREFIX}/conf/systemd.minio.service.template"

    render_template /work/mount_root/templates/install_redis_service.sh.in \
      "${SDK_PREFIX}/install_redis_service.sh"
    chmod +x "${SDK_PREFIX}/install_redis_service.sh"
    render_template /work/mount_root/templates/uninstall_redis_service.sh.in \
      "${SDK_PREFIX}/uninstall_redis_service.sh"
    chmod +x "${SDK_PREFIX}/uninstall_redis_service.sh"
    render_template /work/mount_root/templates/install_minio_service.sh.in \
      "${SDK_PREFIX}/install_minio_service.sh"
    chmod +x "${SDK_PREFIX}/install_minio_service.sh"
    render_template /work/mount_root/templates/uninstall_minio_service.sh.in \
      "${SDK_PREFIX}/uninstall_minio_service.sh"
    chmod +x "${SDK_PREFIX}/uninstall_minio_service.sh"
  else
    install -m 644 /work/mount_root/templates/redis.windows.conf.in \
      "${SDK_PREFIX}/conf/redis.windows.conf.template"
    install -m 644 /work/mount_root/templates/winsw.redis.xml.in \
      "${SDK_PREFIX}/conf/winsw.redis.xml.template"
    install -m 644 /work/mount_root/templates/winsw.minio.xml.in \
      "${SDK_PREFIX}/conf/winsw.minio.xml.template"
    install -m 644 /work/mount_root/templates/minio.env.in \
      "${SDK_PREFIX}/conf/minio.env.template"

    render_template /work/mount_root/templates/install_redis_service.cmd.in \
      "${SDK_PREFIX}/install_redis_service.cmd"
    render_template /work/mount_root/templates/uninstall_redis_service.cmd.in \
      "${SDK_PREFIX}/uninstall_redis_service.cmd"
    render_template /work/mount_root/templates/install_minio_service.cmd.in \
      "${SDK_PREFIX}/install_minio_service.cmd"
    render_template /work/mount_root/templates/uninstall_minio_service.cmd.in \
      "${SDK_PREFIX}/uninstall_minio_service.cmd"
  fi
}

write_package_readme() {
  local redis_status="enabled"
  local patchelf_status="enabled"
  local winsw_status="disabled"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    redis_status="disabled: upstream Redis server does not support native Windows builds"
    patchelf_status="disabled: patchelf is an ELF utility"
  fi

  render_template \
    /work/mount_root/templates/README.middleware.in \
    "${SDK_PREFIX}/README.middleware" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "REDIS_VERSION=${REDIS_VERSION}" \
    "GO_VERSION=${GO_VERSION}" \
    "MINIO_REF=${MINIO_REF}" \
    "ETCD_VERSION=${ETCD_VERSION}" \
    "PATCHELF_VERSION=${PATCHELF_VERSION}" \
    "WINSW_VERSION=${WINSW_VERSION}" \
    "REDIS_STATUS=${redis_status}" \
    "PATCHELF_STATUS=${patchelf_status}" \
    "WINSW_STATUS=${winsw_status}"
}

write_manifest() {
  local redis_status="enabled"
  local patchelf_status="enabled"
  local winsw_status="disabled"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    redis_status="disabled"
    patchelf_status="disabled"
  fi

  cat >"${SDK_PREFIX}/manifest.env" <<EOF
TARGET_TRIPLE=${TARGET_TRIPLE}
REDIS_VERSION=${REDIS_VERSION}
REDIS_STATUS=${redis_status}
GO_VERSION=${GO_VERSION}
MINIO_REF=${MINIO_REF}
ETCD_VERSION=${ETCD_VERSION}
PATCHELF_VERSION=${PATCHELF_VERSION}
PATCHELF_STATUS=${patchelf_status}
WINSW_VERSION=${WINSW_VERSION}
WINSW_STATUS=${winsw_status}
EOF
}

CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
SDK_PREFIX="${SDK_PREFIX:?SDK_PREFIX is required}"
TARGET_TRIPLE="${TARGET_TRIPLE:?TARGET_TRIPLE is required}"
TARGET_KIND="${TARGET_KIND:?TARGET_KIND is required}"
ARCH="${ARCH:?ARCH is required}"
JOBS="${JOBS:-4}"

REDIS_VERSION="${REDIS_VERSION:-7.4.9}"
GO_VERSION="${GO_VERSION:-1.25.10}"
MINIO_REF="${MINIO_REF:-RELEASE.2024-06-22T05-26-45Z}"
ETCD_VERSION="${ETCD_VERSION:-3.6.12}"
PATCHELF_VERSION="${PATCHELF_VERSION:-0.19.0}"
WINSW_VERSION="${WINSW_VERSION:-2.12.0}"

LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-18.1.8}"
CROSS_PREFIX="$(target_cross_cc_prefix)"
GOOS="$(target_goos)"
GOARCH="$(target_goarch)"
BUILD_TOOLS="${BUILD_DIR}/tools"

prepare_build_tool_wrappers

CC="${CC:-${BUILD_TOOLS}/${TARGET_TRIPLE}-cc}"
CXX="${CXX:-${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx}"
AR="${AR:-${LLVM_ROOT}/bin/llvm-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/llvm-ranlib}"
NM="${NM:-${LLVM_ROOT}/bin/llvm-nm}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/llvm-strip}"
LD="${LD:-${LLVM_ROOT}/bin/ld.lld}"

COMMON_CFLAGS="${COMMON_CFLAGS:--O2 -pipe}"
COMMON_LDFLAGS="${COMMON_LDFLAGS:-}"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_CFLAGS="${COMMON_CFLAGS} -fPIC"
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -static-libgcc"
else
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,--nxcompat -Wl,--dynamicbase"
fi

SOURCE_DIR="${BUILD_DIR}/src"
mkdir -p "$SOURCE_DIR" "${SDK_PREFIX}/bin" "${BUILD_DIR}/go-home" "${BUILD_DIR}/go/cache" "${CACHE_DIR}/go/pkg/mod"

download_archive "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" "redis-${REDIS_VERSION}.tar.gz"
download_archive "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" "go${GO_VERSION}.linux-amd64.tar.gz"
download_archive "https://github.com/minio/minio/archive/refs/tags/${MINIO_REF}.tar.gz" "minio-${MINIO_REF}.tar.gz"
download_archive "https://github.com/etcd-io/etcd/archive/refs/tags/v${ETCD_VERSION}.tar.gz" "etcd-${ETCD_VERSION}.tar.gz"
download_archive "https://github.com/NixOS/patchelf/releases/download/${PATCHELF_VERSION}/patchelf-${PATCHELF_VERSION}.tar.bz2" "patchelf-${PATCHELF_VERSION}.tar.bz2"

extract_source "${SOURCE_DIR}/redis" "redis-${REDIS_VERSION}.tar.gz" "src/server.c"
extract_source "${SOURCE_DIR}/minio" "minio-${MINIO_REF}.tar.gz" "go.mod"
extract_source "${SOURCE_DIR}/etcd" "etcd-${ETCD_VERSION}.tar.gz" "go.mod"
extract_source "${SOURCE_DIR}/patchelf" "patchelf-${PATCHELF_VERSION}.tar.bz2" "src/patchelf.cc"
install_go_toolchain

build_redis
build_minio
build_etcd
build_patchelf
write_service_files
write_package_readme
write_manifest

find "$SDK_PREFIX" -type f \( -name '*.a' -o -name '*.la' \) -delete
log "middleware package staged at ${SDK_PREFIX}"
