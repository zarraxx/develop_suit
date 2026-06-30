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

apply_source_patch() {
  local source_dir="$1"
  local patch_path="$2"

  [[ -f "$patch_path" ]] || die "missing patch: ${patch_path}"
  (
    cd "$source_dir"
    if patch -N -p1 --dry-run -i "$patch_path" >/dev/null 2>&1; then
      patch -N -p1 -i "$patch_path"
    elif patch -R -p1 --dry-run -i "$patch_path" >/dev/null 2>&1; then
      :
    else
      die "patch cannot be applied cleanly: ${patch_path}"
    fi
  )
}

target_cross_cc_prefix() {
  case "$TARGET_TRIPLE" in
    x86_64-unknown-linux-gnu)
      printf '%s\n' ""
      ;;
    aarch64-unknown-linux-gnu)
      printf '%s\n' "aarch64-linux-gnu-"
      ;;
    riscv64-unknown-linux-gnu)
      printf '%s\n' "riscv64-linux-gnu-"
      ;;
    loongarch64-unknown-linux-gnu)
      printf '%s\n' "loongarch64-linux-gnu-"
      ;;
    x86_64-w64-windows-gnu)
      printf '%s\n' "x86_64-w64-windows-gnu-"
      ;;
    *)
      die "unsupported target triple: ${TARGET_TRIPLE}"
      ;;
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
    compiler_flags="--sysroot=/opt/${TARGET_TRIPLE}/sysroot -B/opt/${TARGET_TRIPLE}/bin -isystem /opt/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/include -L/opt/${TARGET_TRIPLE}/lib -L/opt/${TARGET_TRIPLE}/sysroot/usr/${TARGET_TRIPLE}/lib -fuse-ld=lld"
  else
    compiler_flags="--sysroot=/opt/sysroot/${TARGET_TRIPLE} -fuse-ld=lld"
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

openssl_target() {
  case "$TARGET_TRIPLE" in
    x86_64-unknown-linux-gnu) printf '%s\n' "linux-x86_64" ;;
    aarch64-unknown-linux-gnu) printf '%s\n' "linux-aarch64" ;;
    riscv64-unknown-linux-gnu) printf '%s\n' "linux64-riscv64" ;;
    loongarch64-unknown-linux-gnu) printf '%s\n' "linux64-loongarch64" ;;
    x86_64-w64-windows-gnu) printf '%s\n' "mingw64" ;;
    *) die "unsupported OpenSSL target for ${TARGET_TRIPLE}" ;;
  esac
}

autotools_host_triple() {
  case "$TARGET_TRIPLE" in
    x86_64-w64-windows-gnu)
      printf '%s\n' "x86_64-w64-mingw32"
      ;;
    *)
      printf '%s\n' "$TARGET_TRIPLE"
      ;;
  esac
}

host_env() {
  local ld_library_path="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
  local qemu_ld_prefix="${QEMU_LD_PREFIX:-}"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    ld_library_path="${SDK_PREFIX}/bin:${ld_library_path}"
  elif [[ "$ARCH" != "x86_64" ]]; then
    qemu_ld_prefix="/opt/sysroot/${TARGET_TRIPLE}"
  fi

  env \
    PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}" \
    LD_LIBRARY_PATH="${ld_library_path}" \
    PKG_CONFIG_SYSROOT_DIR= \
    CC="$CC" \
    CXX="$CXX" \
    LD="$LD" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    NM="$NM" \
    STRIP="$STRIP" \
    WINDRES="${WINDRES:-}" \
    RC="${WINDRES:-}" \
    QEMU_LD_PREFIX="$qemu_ld_prefix" \
    CPPFLAGS="${COMMON_CPPFLAGS} ${CPPFLAGS:-}" \
    CFLAGS="${COMMON_CFLAGS} ${CFLAGS:-}" \
    CXXFLAGS="${COMMON_CXXFLAGS} ${CXXFLAGS:-}" \
    LDFLAGS="${COMMON_LDFLAGS} ${LDFLAGS:-}" \
    "$@"
}

write_default_config() {
  render_template \
    /work/mount_root/templates/nginx.conf.in \
    "${SDK_PREFIX}/conf/nginx.conf" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}"
}

write_package_readme() {
  render_template \
    /work/mount_root/templates/README.nginx.in \
    "${SDK_PREFIX}/README.nginx" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "NGINX_VERSION=${NGINX_VERSION}" \
    "OPENSSL_VERSION=${OPENSSL_VERSION}" \
    "PCRE2_VERSION=${PCRE2_VERSION}" \
    "ZLIB_VERSION=${ZLIB_VERSION}" \
    "CURL_VERSION=${CURL_VERSION}" \
    "PROXY_CONNECT_REPO=${PROXY_CONNECT_REPO}" \
    "PROXY_CONNECT_REF=${PROXY_CONNECT_REF}" \
    "PROXY_CONNECT_PATCH=${PROXY_CONNECT_PATCH}"
}

write_service_installers() {
  render_template "/work/mount_root/templates/install_service.sh.in" \
    "${SDK_PREFIX}/install_service.sh"
  chmod +x "${SDK_PREFIX}/install_service.sh"

  render_template "/work/mount_root/templates/install_service.cmd.in" \
    "${SDK_PREFIX}/install_service.cmd"

  render_template "/work/mount_root/templates/uninstall_service.sh.in" \
    "${SDK_PREFIX}/uninstall_service.sh"
  chmod +x "${SDK_PREFIX}/uninstall_service.sh"

  render_template "/work/mount_root/templates/uninstall_service.cmd.in" \
    "${SDK_PREFIX}/uninstall_service.cmd"
}

stage_nginx_static_deps_for_curl() {
  local openssl_prefix="${SOURCE_DIR}/openssl/.openssl"

  [[ -f "${openssl_prefix}/lib/libssl.a" ]] || die "missing bundled OpenSSL libssl.a for curl"
  [[ -f "${openssl_prefix}/lib/libcrypto.a" ]] || die "missing bundled OpenSSL libcrypto.a for curl"
  [[ -f "${SOURCE_DIR}/zlib/libz.a" ]] || die "missing bundled zlib libz.a for curl"

  rm -rf "$CURL_DEPS_PREFIX"
  mkdir -p "${CURL_DEPS_PREFIX}/include" "${CURL_DEPS_PREFIX}/lib"
  cp -a "${openssl_prefix}/include/." "${CURL_DEPS_PREFIX}/include/"
  cp -a "${openssl_prefix}/lib/libssl.a" "${openssl_prefix}/lib/libcrypto.a" "${CURL_DEPS_PREFIX}/lib/"
  cp -a "${SOURCE_DIR}/zlib/zlib.h" "${SOURCE_DIR}/zlib/zconf.h" "${CURL_DEPS_PREFIX}/include/"
  cp -a "${SOURCE_DIR}/zlib/libz.a" "${CURL_DEPS_PREFIX}/lib/"
}

build_curl_static() {
  local source_dir="${SOURCE_DIR}/curl"
  local build_dir="${BUILD_DIR}/curl-build"
  local exeext=""
  local curl_host="$AUTOTOOLS_HOST_TRIPLE"
  local curl_libs="-lssl -lcrypto -lz"
  local curl_ldflags="-L${CURL_DEPS_PREFIX}/lib ${COMMON_LDFLAGS}"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    exeext=".exe"
    curl_libs="${curl_libs} -lws2_32 -lcrypt32 -lbcrypt -ladvapi32 -liphlpapi"
  else
    curl_libs="${curl_libs} -ldl -lpthread"
  fi

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cp -a "${source_dir}/." "$build_dir/"

  log "Configuring curl ${CURL_VERSION} static client"
  (
    cd "$build_dir"
    host_env \
      CPPFLAGS="-I${CURL_DEPS_PREFIX}/include ${CPPFLAGS:-}" \
      LDFLAGS="$curl_ldflags" \
      LIBS="$curl_libs" \
      PKG_CONFIG=false \
      ./configure \
        --build="$BUILD_TRIPLE" \
        --host="$curl_host" \
        --prefix="$SDK_PREFIX" \
        --disable-shared \
        --enable-static \
        --enable-ech \
        --disable-libcurl-option \
        --disable-manual \
        --disable-docs \
        --disable-ldap \
        --disable-ldaps \
        --disable-rtsp \
        --without-brotli \
        --without-zstd \
        --without-libpsl \
        --without-libidn2 \
        --without-nghttp2 \
        --without-nghttp3 \
        --without-ngtcp2 \
        --without-quiche \
        --with-openssl="$CURL_DEPS_PREFIX" \
        --with-zlib="$CURL_DEPS_PREFIX"
    host_env make -j "$JOBS"
    install -d "${SDK_PREFIX}/bin"
    install -m 755 "src/curl${exeext}" "${SDK_PREFIX}/bin/curl_static${exeext}"
  )

  [[ -x "${SDK_PREFIX}/bin/curl_static${exeext}" ]] || die "curl_static install did not produce ${SDK_PREFIX}/bin/curl_static${exeext}"
  if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" ]]; then
    "${SDK_PREFIX}/bin/curl_static" -V | grep -q "OpenSSL/${OPENSSL_VERSION}" \
      || die "curl_static is not linked with OpenSSL ${OPENSSL_VERSION}"
  fi
}

build_nginx() {
  local source_dir="${SOURCE_DIR}/nginx"
  local proxy_connect_dir="${SOURCE_DIR}/ngx_http_proxy_connect_module"
  local build_dir="${BUILD_DIR}/nginx-build"
  local nginx_platform=""
  local exeext=""
  local configure_args=()
  local openssl_opts=()

  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cp -a "${source_dir}/." "$build_dir/"

  apply_source_patch "$build_dir" "/work/mount_root/patch/nginx-1.30.3-pcre-conf-opt.patch"
  apply_source_patch "$build_dir" "${proxy_connect_dir}/${PROXY_CONNECT_PATCH}"

  openssl_opts=(
    "$OPENSSL_TARGET"
    "no-shared"
    "no-tests"
    "no-module"
    "-fPIC"
    "--libdir=lib"
    "--openssldir=${SDK_PREFIX}/ssl"
    "--cross-compile-prefix="
  )

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    nginx_platform="win32"
    exeext=".exe"
    openssl_opts=(
      "$OPENSSL_TARGET"
      "no-shared"
      "no-tests"
      "no-module"
      "--libdir=lib"
      "--openssldir=${SDK_PREFIX}/ssl"
      "--cross-compile-prefix="
    )
  fi

  configure_args=(
    "--prefix=${SDK_PREFIX}"
    "--sbin-path=${SDK_PREFIX}/sbin/nginx${exeext}"
    "--conf-path=${SDK_PREFIX}/conf/nginx.conf"
    "--pid-path=${SDK_PREFIX}/run/nginx.pid"
    "--lock-path=${SDK_PREFIX}/run/nginx.lock"
    "--http-log-path=${SDK_PREFIX}/logs/access.log"
    "--error-log-path=${SDK_PREFIX}/logs/error.log"
    "--with-cc=${CC}"
    "--with-cc-opt=${COMMON_CPPFLAGS} ${COMMON_CFLAGS}"
    "--with-ld-opt=${COMMON_LDFLAGS}"
    "--with-openssl=${SOURCE_DIR}/openssl"
    "--with-openssl-opt=${openssl_opts[*]}"
    "--with-pcre=${SOURCE_DIR}/pcre2"
    "--with-pcre-conf-opt=--host=${AUTOTOOLS_HOST_TRIPLE}"
    "--with-pcre-jit"
    "--with-zlib=${SOURCE_DIR}/zlib"
    "--add-module=${proxy_connect_dir}"
    "--with-compat"
    "--with-http_ssl_module"
    "--with-http_v2_module"
    "--with-http_realip_module"
    "--with-http_addition_module"
    "--with-http_auth_request_module"
    "--with-http_sub_module"
    "--with-http_dav_module"
    "--with-http_flv_module"
    "--with-http_mp4_module"
    "--with-http_gunzip_module"
    "--with-http_gzip_static_module"
    "--with-http_random_index_module"
    "--with-http_secure_link_module"
    "--with-http_slice_module"
    "--with-http_stub_status_module"
    "--with-stream"
    "--with-stream_ssl_module"
    "--with-stream_ssl_preread_module"
    "--with-mail"
    "--with-mail_ssl_module"
  )

  if [[ -n "$nginx_platform" ]]; then
    configure_args+=("--crossbuild=${nginx_platform}")
  fi
  if [[ "$TARGET_KIND" == "linux" ]]; then
    configure_args+=(
      "--with-file-aio"
      "--with-threads"
      "--with-http_v3_module"
    )
  fi

  log "Configuring nginx ${NGINX_VERSION}"
  (
    cd "$build_dir"
    host_env ./configure "${configure_args[@]}"
    host_env make -j "$JOBS"
    host_env make install
  )

  mkdir -p "${SDK_PREFIX}/run" "${SDK_PREFIX}/logs" "${SDK_PREFIX}/html"
  [[ -x "${SDK_PREFIX}/sbin/nginx${exeext}" ]] || die "nginx install did not produce ${SDK_PREFIX}/sbin/nginx${exeext}"
}

CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
SDK_PREFIX="${SDK_PREFIX:?SDK_PREFIX is required}"
TARGET_TRIPLE="${TARGET_TRIPLE:?TARGET_TRIPLE is required}"
TARGET_KIND="${TARGET_KIND:?TARGET_KIND is required}"
ARCH="${ARCH:?ARCH is required}"
JOBS="${JOBS:-4}"

NGINX_VERSION="${NGINX_VERSION:-1.30.3}"
OPENSSL_VERSION="${OPENSSL_VERSION:-4.0.1}"
PCRE2_VERSION="${PCRE2_VERSION:-10.47}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
CURL_VERSION="${CURL_VERSION:-8.21.0}"
PROXY_CONNECT_REPO="${PROXY_CONNECT_REPO:-https://github.com/hanjeongsang/ngx_http_proxy_connect_module}"
PROXY_CONNECT_REF="${PROXY_CONNECT_REF:-master}"
PROXY_CONNECT_PATCH="${PROXY_CONNECT_PATCH:-patch/proxy_connect_rewrite_103001.patch}"

LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-18.1.8}"
BUILD_TRIPLE="$(cc -dumpmachine 2>/dev/null || printf '%s\n' x86_64-pc-linux-gnu)"
CROSS_PREFIX="$(target_cross_cc_prefix)"
OPENSSL_TARGET="$(openssl_target)"
AUTOTOOLS_HOST_TRIPLE="$(autotools_host_triple)"
BUILD_TOOLS="${BUILD_DIR}/tools"

prepare_build_tool_wrappers

CC="${CC:-${BUILD_TOOLS}/${TARGET_TRIPLE}-cc}"
CXX="${CXX:-${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx}"
AR="${AR:-${LLVM_ROOT}/bin/llvm-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/llvm-ranlib}"
NM="${NM:-${LLVM_ROOT}/bin/llvm-nm}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/llvm-strip}"
LD="${LD:-${LLVM_ROOT}/bin/ld.lld}"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  WINDRES="${WINDRES:-${BUILD_TOOLS}/${TARGET_TRIPLE}-windres}"
else
  WINDRES="${WINDRES:-}"
fi

COMMON_CPPFLAGS="${COMMON_CPPFLAGS:-}"
COMMON_CFLAGS="${COMMON_CFLAGS:--O2 -pipe}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:--O2 -pipe}"
COMMON_LDFLAGS="${COMMON_LDFLAGS:-}"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_CFLAGS="${COMMON_CFLAGS} -fPIC"
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -static-libgcc"
else
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,--nxcompat -Wl,--dynamicbase"
fi

SOURCE_DIR="${BUILD_DIR}/src"
CURL_DEPS_PREFIX="${BUILD_DIR}/curl-static-deps"
mkdir -p "$SOURCE_DIR" "$SDK_PREFIX"

download_archive "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "nginx-${NGINX_VERSION}.tar.gz"
download_archive "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}.tar.gz"
download_archive "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" "pcre2-${PCRE2_VERSION}.tar.gz"
download_archive "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}.tar.gz"
download_archive "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" "curl-${CURL_VERSION}.tar.xz"
download_archive "${PROXY_CONNECT_REPO}/archive/${PROXY_CONNECT_REF}.tar.gz" "ngx_http_proxy_connect_module-${PROXY_CONNECT_REF}.tar.gz"

extract_source "${SOURCE_DIR}/nginx" "nginx-${NGINX_VERSION}.tar.gz" "configure"
extract_source "${SOURCE_DIR}/openssl" "openssl-${OPENSSL_VERSION}.tar.gz" "Configure"
extract_source "${SOURCE_DIR}/pcre2" "pcre2-${PCRE2_VERSION}.tar.gz" "configure"
extract_source "${SOURCE_DIR}/zlib" "zlib-${ZLIB_VERSION}.tar.gz" "configure"
extract_source "${SOURCE_DIR}/curl" "curl-${CURL_VERSION}.tar.xz" "configure"
extract_source "${SOURCE_DIR}/ngx_http_proxy_connect_module" "ngx_http_proxy_connect_module-${PROXY_CONNECT_REF}.tar.gz" "$PROXY_CONNECT_PATCH"

build_nginx
stage_nginx_static_deps_for_curl
build_curl_static
write_default_config
write_package_readme
write_service_installers

find "$SDK_PREFIX" -type f \( -name '*.a' -o -name '*.la' \) -delete
find "$SDK_PREFIX" -type f -name '*.old' -delete
log "nginx package staged at ${SDK_PREFIX}"
