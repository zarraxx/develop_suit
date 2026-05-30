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

extract_archive_source() {
  local source_dir="$1"
  local archive_name="$2"
  local marker_path="$3"
  local archive_marker="${source_dir}/.postgresql-dependencies-source-archive"

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

apply_source_patch_once() {
  local source_dir="$1"
  local patch_path="$2"
  local patch_name
  patch_name="$(basename "$patch_path")"

  if [[ ! -f "${source_dir}/.patched-${patch_name}" ]]; then
    (
      cd "$source_dir"
      patch -p1 -i "$patch_path"
    )
    touch "${source_dir}/.patched-${patch_name}"
  fi
}

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"

  render_template "${TEMPLATE_DIR}/clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}"
  chmod +x "$wrapper_path"
}

write_windres_wrapper() {
  local wrapper_path="$1"
  local real_windres="$2"

  render_template "${TEMPLATE_DIR}/windres-wrapper.in" "$wrapper_path" \
    "REAL_WINDRES=${real_windres}" \
    "SYSROOT=${SYSROOT}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "TARGET_ROOT=${TARGET_ROOT}"
  chmod +x "$wrapper_path"
}

write_toolchain_file() {
  render_template "${TEMPLATE_DIR}/cmake-toolchain.cmake.in" "$TOOLCHAIN_FILE" \
    "CMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}" \
    "CMAKE_SYSTEM_PROCESSOR=${CMAKE_SYSTEM_PROCESSOR}" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "LD=${LD}" \
    "NM=${NM}" \
    "OBJCOPY=${OBJCOPY}" \
    "RANLIB=${RANLIB}" \
    "STRIP=${STRIP}" \
    "RC=${RC}" \
    "RC_FLAGS=${RC_FLAGS}" \
    "SYSROOT=${SYSROOT}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_ROOT=${TARGET_ROOT}" \
    "LLVM_ROOT=${LLVM_ROOT}"
}

write_meson_cross_file() {
  render_template "${TEMPLATE_DIR}/meson-cross.ini.in" "$MESON_CROSS_FILE" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "STRIP=${STRIP}" \
    "SYSROOT=${SYSROOT}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "MESON_EXTRA_C_ARGS=${MESON_EXTRA_C_ARGS}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "MESON_SYSTEM=${MESON_SYSTEM}" \
    "MESON_CPU_FAMILY=${MESON_CPU_FAMILY}" \
    "MESON_CPU=${MESON_CPU}"
}

prepare_linux_compat_headers() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  rm -rf "$BUILD_COMPAT_INCLUDE"
  mkdir -p "${BUILD_COMPAT_INCLUDE}/linux"
  render_template "${TEMPLATE_DIR}/linux-kcmp.h.in" "${BUILD_COMPAT_INCLUDE}/linux/kcmp.h"
  render_template "${TEMPLATE_DIR}/postgresql-deps-compat.h.in" "${BUILD_COMPAT_INCLUDE}/postgresql-deps-compat.h"
  render_template "${TEMPLATE_DIR}/threads.h.in" "${BUILD_COMPAT_INCLUDE}/threads.h"
}

linux_syscall_meson_c_args() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  local add_key=217
  local bpf=280
  local close_range=436
  local fchmodat2=452
  local fsconfig=431
  local fsmount=432
  local fsopen=430
  local get_mempolicy=236
  local gettid=178
  local ioprio_get=31
  local ioprio_set=30
  local kcmp=272
  local keyctl=219
  local memfd_create=279
  local mount_setattr=442
  local move_mount=429
  local open_tree=428
  local open_tree_attr=467
  local pidfd_open=434
  local pidfd_send_signal=424
  local pivot_root=41
  local quotactl_fd=443
  local removexattrat=466
  local renameat2=276
  local request_key=218
  local rt_tgsigqueueinfo=240
  local sched_setattr=274
  local set_mempolicy=237
  local setxattrat=463

  if [[ "$ARCH" == "x86_64" ]]; then
    add_key=248
    bpf=321
    get_mempolicy=239
    gettid=186
    ioprio_get=252
    ioprio_set=251
    kcmp=312
    keyctl=250
    memfd_create=319
    pivot_root=155
    renameat2=316
    request_key=249
    rt_tgsigqueueinfo=297
    sched_setattr=314
    set_mempolicy=238
  fi

  printf "%s" \
    ", '-I${BUILD_COMPAT_INCLUDE}'" \
    ", '-include', '${BUILD_COMPAT_INCLUDE}/postgresql-deps-compat.h'" \
    ", '-D_GNU_SOURCE'" \
    ", '-D__NR_add_key=${add_key}'" \
    ", '-D__NR_bpf=${bpf}'" \
    ", '-D__NR_close_range=${close_range}'" \
    ", '-D__NR_fchmodat2=${fchmodat2}'" \
    ", '-D__NR_fsconfig=${fsconfig}'" \
    ", '-D__NR_fsmount=${fsmount}'" \
    ", '-D__NR_fsopen=${fsopen}'" \
    ", '-D__NR_get_mempolicy=${get_mempolicy}'" \
    ", '-D__NR_gettid=${gettid}'" \
    ", '-D__NR_ioprio_get=${ioprio_get}'" \
    ", '-D__NR_ioprio_set=${ioprio_set}'" \
    ", '-D__NR_kcmp=${kcmp}'" \
    ", '-D__NR_keyctl=${keyctl}'" \
    ", '-D__NR_memfd_create=${memfd_create}'" \
    ", '-D__NR_mount_setattr=${mount_setattr}'" \
    ", '-D__NR_move_mount=${move_mount}'" \
    ", '-D__NR_open_tree=${open_tree}'" \
    ", '-D__NR_open_tree_attr=${open_tree_attr}'" \
    ", '-D__NR_pidfd_open=${pidfd_open}'" \
    ", '-D__NR_pidfd_send_signal=${pidfd_send_signal}'" \
    ", '-D__NR_pivot_root=${pivot_root}'" \
    ", '-D__NR_quotactl_fd=${quotactl_fd}'" \
    ", '-D__NR_removexattrat=${removexattrat}'" \
    ", '-D__NR_renameat2=${renameat2}'" \
    ", '-D__NR_request_key=${request_key}'" \
    ", '-D__NR_rt_tgsigqueueinfo=${rt_tgsigqueueinfo}'" \
    ", '-D__NR_sched_setattr=${sched_setattr}'" \
    ", '-D__NR_set_mempolicy=${set_mempolicy}'" \
    ", '-D__NR_setxattrat=${setxattrat}'"
}

write_realpath_wrapper() {
  local wrapper_path="${BUILD_TOOLS}/realpath"

  render_template "${TEMPLATE_DIR}/realpath-wrapper.in" "$wrapper_path"
  chmod +x "$wrapper_path"
}

write_printf_wrapper() {
  local wrapper_path="${BUILD_TOOLS}/printf"

  render_template "${TEMPLATE_DIR}/printf-wrapper.in" "$wrapper_path"
  chmod +x "$wrapper_path"
}

write_ln_wrapper() {
  local wrapper_path="${BUILD_TOOLS}/ln"

  render_template "${TEMPLATE_DIR}/ln-wrapper.in" "$wrapper_path"
  chmod +x "$wrapper_path"
}

write_rsync_wrapper() {
  local wrapper_path="${BUILD_TOOLS}/rsync"

  render_template "${TEMPLATE_DIR}/rsync-wrapper.in" "$wrapper_path"
  chmod +x "$wrapper_path"
}

install_build_python_package() {
  local source_dir="$1"
  local package_dir="$2"
  local python_site_dir="${BUILD_TOOLS}/python"

  mkdir -p "$python_site_dir"
  if [[ -d "${source_dir}/src/${package_dir}" ]]; then
    rm -rf "${python_site_dir}/${package_dir}"
    cp -a "${source_dir}/src/${package_dir}" "${python_site_dir}/"
  elif [[ -d "${source_dir}/${package_dir}" ]]; then
    rm -rf "${python_site_dir}/${package_dir}"
    cp -a "${source_dir}/${package_dir}" "${python_site_dir}/"
  else
    die "missing Python package directory ${package_dir} in ${source_dir}"
  fi
}

build_python_jinja2() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  install_build_python_package "${DEP_SOURCE_DIR}/markupsafe" "markupsafe"
  install_build_python_package "${DEP_SOURCE_DIR}/jinja2" "jinja2"

  export PYTHONPATH="${BUILD_TOOLS}/python${PYTHONPATH:+:${PYTHONPATH}}"
  python3 - <<'PY'
import jinja2
print("build python jinja2:", jinja2.__version__)
PY
}

configure_make_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  local extra_env=()
  if declare -p CONFIGURE_ENV_EXTRA >/dev/null 2>&1; then
    extra_env=("${CONFIGURE_ENV_EXTRA[@]}")
  fi

  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring dependency: ${package_name}"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${PATH}"
    env \
      CC="$CC" \
      CXX="$CXX" \
      LD="$LD" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      OBJCOPY="$OBJCOPY" \
      OBJDUMP="$OBJDUMP" \
      DLLTOOL="$DLLTOOL" \
      RC="$RC" \
      WINDRES="$RC" \
      CC_FOR_BUILD="$BUILD_CC" \
      BUILD_CC="$BUILD_CC" \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBS="${LIBS:-}" \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR= \
      krb5_cv_attr_constructor_destructor="${krb5_cv_attr_constructor_destructor:-yes,yes}" \
      ac_cv_printf_positional="${ac_cv_printf_positional:-yes}" \
      ac_cv_search_dgettext="${ac_cv_search_dgettext:--lintl}" \
      ac_cv_gssapi_supports_spnego="${ac_cv_gssapi_supports_spnego:-yes}" \
      "${extra_env[@]}" \
      "${source_dir}/configure" \
        --build="$CONFIGURE_BUILD_TRIPLE" \
        --host="$CONFIGURE_HOST_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        "$@"
    make -j "$JOBS"
    make install
  )
}

cmake_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  local cmake_target_args=()
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cmake_target_args+=(-DCMAKE_DLL_NAME_WITH_SOVERSION=ON)
  fi

  log "Configuring dependency: ${package_name}"
  cmake -S "$source_dir" -B "$package_build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
    "${cmake_target_args[@]}" \
    "$@"

  log "Building dependency: ${package_name}"
  cmake --build "$package_build_dir" --parallel "$JOBS"
  cmake --install "$package_build_dir"
}

meson_install() {
  local package_name="$1"
  local source_dir="$2"
  shift 2

  local package_build_dir="${DEP_BUILD_DIR}/${package_name}"
  local stage_dir="${package_build_dir}/stage"
  rm -rf "$package_build_dir"

  log "Configuring dependency: ${package_name}"
  env \
    PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR= \
    meson setup "$package_build_dir" "$source_dir" \
      --cross-file="$MESON_CROSS_FILE" \
      --prefix="$SDK_PREFIX" \
      --libdir=lib \
      --buildtype=release \
      "$@"

  log "Building dependency: ${package_name}"
  meson compile -C "$package_build_dir" -j "$JOBS"
  DESTDIR="$stage_dir" meson install -C "$package_build_dir"
  cp -a "${stage_dir}${SDK_PREFIX}/." "$SDK_PREFIX/"
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete
  find "${SDK_PREFIX}/lib" -type f -name '*.a' ! -name '*.dll.a' -delete
}

remove_unneeded_docs() {
  rm -rf "${SDK_PREFIX}/share/doc" "${SDK_PREFIX}/share/man" "${SDK_PREFIX}/share/info"
}

rewrite_dependency_prefixes() {
  local installed_file=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.py|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    if grep -IqF "/opt/python_dependencies-${TARGET_TRIPLE}" "$installed_file"; then
      sed -i "s#/opt/python_dependencies-${TARGET_TRIPLE}#${SDK_PREFIX}#g" "$installed_file"
    fi
  done < <(find "$SDK_PREFIX" -type f -print0 2>/dev/null)
}

copy_dependency_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"
  find "$SDK_PREFIX" \
    -path "${SDK_PREFIX}/bin" -prune \
    -o -type f -name '*.dll' -exec cp -f {} "${SDK_PREFIX}/bin/" \;
}

build_keyutils() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  local source_dir="${DEP_SOURCE_DIR}/keyutils"
  local package_build_dir="${DEP_BUILD_DIR}/keyutils"
  local stage_dir="${package_build_dir}/stage"

  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"
  cp -a "${source_dir}/." "$package_build_dir/"

  log "Building dependency: keyutils"
  (
    cd "$package_build_dir"
    make -j "$JOBS" \
      CC="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      CFLAGS="$COMMON_CPPFLAGS $COMMON_CFLAGS -fPIC" \
      LDFLAGS="$COMMON_LDFLAGS -Wl,--undefined-version" \
      NO_ARLIB=1 \
      NO_GLIBC_KEYERR=1
    make install \
      DESTDIR="$stage_dir" \
      PREFIX="$SDK_PREFIX" \
      LIBDIR="${SDK_PREFIX}/lib" \
      USRLIBDIR="${SDK_PREFIX}/lib" \
      INCLUDEDIR="${SDK_PREFIX}/include" \
      NO_ARLIB=1
  )
  cp -a "${stage_dir}${SDK_PREFIX}/." "$SDK_PREFIX/"
  ln -sfn libkeyutils.so.1 "${SDK_PREFIX}/lib/libkeyutils.so"
}

build_liburing() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  local package_build_dir="${DEP_BUILD_DIR}/liburing"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"
  cp -a "${DEP_SOURCE_DIR}/liburing/." "$package_build_dir/"

  log "Configuring dependency: liburing"
  (
    cd "$package_build_dir"
    ./configure \
      --prefix="$SDK_PREFIX" \
      --libdir="${SDK_PREFIX}/lib" \
      --cc="$CC" \
      --cxx="$CXX" \
      --use-libc
    make -j "$JOBS" library AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP"
    make install AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP"
  )
}

build_krb5() {
  local CONFIGURE_ENV_EXTRA=()
  local configure_args=(
    --enable-shared
    --disable-static
    --disable-rpath
    --without-tcl
  )

  if [[ "$TARGET_KIND" == "linux" ]]; then
    configure_args+=(--without-system-verto)
  else
    CONFIGURE_ENV_EXTRA+=(
      LIBS="-lws2_32 -ldnsapi -lsecur32"
      ac_cv_func_res_nsearch=yes
      krb5_cv_func_res_nsearch=yes
      krb5_cv_func_res_search=yes
    )
    configure_args+=(--without-system-verto "--with-netlib=-lws2_32 -ldnsapi -lsecur32")
  fi

  configure_make_install krb5 "${DEP_SOURCE_DIR}/krb5/src" "${configure_args[@]}"
}

build_cyrus_sasl() {
  apply_source_patch_once "${DEP_SOURCE_DIR}/cyrus-sasl" "${PATCH_DIR}/cyrus-sasl-time-header.patch"
  apply_source_patch_once "${DEP_SOURCE_DIR}/cyrus-sasl" "${PATCH_DIR}/cyrus-sasl-plugin-time-headers.patch"

  configure_make_install cyrus-sasl "${DEP_SOURCE_DIR}/cyrus-sasl" \
    --enable-shared \
    --disable-static \
    --disable-sample \
    --disable-sql \
    --disable-otp \
    --disable-srp \
    --disable-srp-setpass \
    --disable-krb4 \
    "--with-openssl=${SDK_PREFIX}" \
    --with-gss_impl=mit \
    "--with-krb5=${SDK_PREFIX}"
}

build_openldap() {
  local yielding_select="yes"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    yielding_select="manual"
  fi

  local package_build_dir="${DEP_BUILD_DIR}/openldap"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring dependency: openldap"
  (
    cd "$package_build_dir"
    export PATH="${BUILD_TOOLS}:${PATH}"
    env \
      CC="$CC" \
      CXX="$CXX" \
      LD="$LD" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      OBJCOPY="$OBJCOPY" \
      OBJDUMP="$OBJDUMP" \
      DLLTOOL="$DLLTOOL" \
      RC="$RC" \
      WINDRES="$RC" \
      CC_FOR_BUILD="$BUILD_CC" \
      BUILD_CC="$BUILD_CC" \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBS="${LIBS:-}" \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR= \
      "${DEP_SOURCE_DIR}/openldap/configure" \
        --build="$CONFIGURE_BUILD_TRIPLE" \
        --host="$CONFIGURE_HOST_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        --enable-shared \
        --disable-static \
        --disable-slapd \
        --disable-backends \
        --disable-overlays \
        --with-tls=openssl \
        --with-cyrus-sasl \
        --with-threads \
        "--with-yielding_select=${yielding_select}"
    make -j "$JOBS" -C include
    make -j "$JOBS" -C libraries
    make -C include install
    make -C libraries install
  )
}

build_json_c() {
  local json_c_args=()
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    json_c_args+=(
      -DBSYMBOLIC_WORKS=OFF
      -DDISABLE_BSYMBOLIC=ON
      -DVERSION_SCRIPT_WORKS=OFF
    )
  fi

  cmake_install json-c "${DEP_SOURCE_DIR}/json-c" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DDISABLE_WERROR=ON \
    "${json_c_args[@]}"
}

build_libxcrypt() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  configure_make_install libxcrypt "${DEP_SOURCE_DIR}/libxcrypt" \
    --enable-shared \
    --disable-static \
    --disable-werror \
    --disable-obsolete-api \
    --disable-failure-tokens
}

build_libevent() {
  local libevent_args=()
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    libevent_args+=(-DEVENT__DISABLE_CLOCK_GETTIME=ON)
  fi

  cmake_install libevent "${DEP_SOURCE_DIR}/libevent" \
    -DEVENT__LIBRARY_TYPE=SHARED \
    -DEVENT__DISABLE_SAMPLES=ON \
    -DEVENT__DISABLE_TESTS=ON \
    -DEVENT__DISABLE_BENCHMARK=ON \
    -DEVENT__DISABLE_REGRESS=ON \
    -DEVENT__DISABLE_OPENSSL=OFF \
    -DEVENT__DISABLE_THREAD_SUPPORT=OFF \
    "${libevent_args[@]}"
}

build_native_gperf() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0
  [[ -x "${BUILD_TOOLS}/gperf" ]] && return 0

  local package_build_dir="${DEP_BUILD_DIR}/gperf-build"
  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Building native build tool: gperf"
  (
    cd "$package_build_dir"
    env \
      CC="$BUILD_CC" \
      CXX="$BUILD_CXX" \
      AR="${LLVM_ROOT}/bin/llvm-ar" \
      RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
      NM="${LLVM_ROOT}/bin/llvm-nm" \
      STRIP="${LLVM_ROOT}/bin/llvm-strip" \
      "${DEP_SOURCE_DIR}/gperf/configure" \
        --prefix="$BUILD_DIR/gperf-native" \
        --bindir="$BUILD_TOOLS"
    make -j "$JOBS"
    make install
  )
}

build_linux_pam() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  meson_install linux-pam "${DEP_SOURCE_DIR}/linux-pam" \
    --default-library=shared \
    -Ddocs=disabled \
    -Dexamples=false \
    -Dxtests=false \
    -Di18n=disabled \
    -Deconf=disabled \
    -Dlogind=disabled \
    -Delogind=disabled \
    -Dopenssl=disabled \
    -Dselinux=disabled \
    -Daudit=disabled \
    -Dnis=disabled \
    -Dpam_userdb=disabled \
    -Dpam_unix=disabled

  keep_linux_pam_sdk
}

build_libcap() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  log "Building dependency: libcap"
  make -C "${DEP_SOURCE_DIR}/libcap/libcap" \
    -j "$JOBS" \
    CC="$CC" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    OBJCOPY="$OBJCOPY" \
    BUILD_CC="$BUILD_CC" \
    BUILD_LD="$BUILD_CC" \
    prefix="$SDK_PREFIX" \
    lib=lib \
    PTHREADS=no \
    USE_GPERF=no \
    SHARED=yes
  make -C "${DEP_SOURCE_DIR}/libcap/libcap" \
    install-shared-cap \
    CC="$CC" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    OBJCOPY="$OBJCOPY" \
    BUILD_CC="$BUILD_CC" \
    BUILD_LD="$BUILD_CC" \
    prefix="$SDK_PREFIX" \
    lib=lib \
    PTHREADS=no \
    USE_GPERF=no \
    SHARED=yes
}

build_util_linux_libmount() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  configure_make_install util-linux-libmount "${DEP_SOURCE_DIR}/util-linux" \
    --disable-all-programs \
    --disable-libuuid \
    --enable-libblkid \
    --enable-libmount \
    --disable-libsmartcols \
    --disable-nls \
    --without-python \
    --without-systemd \
    --without-udev \
    --without-selinux \
    --without-audit \
    --without-ncurses \
    --without-ncursesw \
    --without-readline \
    --without-tinfo
}

build_libsystemd() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  if [[ "$SYSTEMD_BUILD_SYSTEM" == "autotools" ]]; then
    build_libsystemd_autotools
  else
    build_libsystemd_meson
  fi
}

build_libsystemd_meson() {
  local systemd_args=()

  if [[ "$SYSTEMD_VERSION" == "241" ]]; then
    systemd_args=(
      --auto-features=disabled
      -Dstatic-libsystemd=false
      -Dtests=false
      -Dslow-tests=false
      -Dinstall-tests=false
      -Dman=false
      -Dhtml=false
      -Dpam=false
      -Dacl=false
      -Daudit=false
      -Dblkid=false
      -Dkmod=false
      -Dseccomp=false
      -Dselinux=false
      -Dapparmor=false
      -Dpolkit=false
      -Dlibcryptsetup=false
      -Dlibcurl=false
      -Dopenssl=false
      -Dzlib=false
      -Dbzip2=false
      -Dxz=false
      -Dlz4=false
      -Dpcre2=false
      -Dfirstboot=false
      -Dutmp=false
      -Dhibernate=false
      -Dldconfig=false
      -Dresolve=false
      -Defi=false
      -Dtpm=false
      -Denvironment-d=false
      -Dbinfmt=false
      -Dcoredump=false
      -Dlogind=false
      -Dhostnamed=false
      -Dlocaled=false
      -Dmachined=false
      -Dportabled=false
      -Dnetworkd=false
      -Dtimedated=false
      -Dtimesyncd=false
      -Dremote=false
      -Dnss-myhostname=false
      -Dnss-mymachines=false
      -Dnss-resolve=false
      -Dnss-systemd=false
      -Drandomseed=false
      -Dbacklight=false
      -Dvconsole=false
      -Dquotacheck=false
      -Dsysusers=false
      -Dtmpfiles=false
      -Dimportd=false
      -Dhwdb=false
      -Drfkill=false
      -Drpmmacrosdir=no
      -Drootlibdir=lib
    )
  else
    systemd_args=(
      --auto-features=disabled
      -Dvcs-tag=false
      -Dstatic-libsystemd=false
      -Dtests=false
      -Dslow-tests=false
      -Dfuzz-tests=false
      -Dinstall-tests=false
      -Dman=disabled
      -Dhtml=disabled
      -Dtranslations=false
      -Dpam=disabled
      -Dacl=disabled
      -Daudit=disabled
      -Dblkid=disabled
      -Dfdisk=disabled
      -Dkmod=disabled
      -Dseccomp=disabled
      -Dselinux=disabled
      -Dapparmor=disabled
      -Dpolkit=disabled
      -Dlibcrypt=disabled
      -Dlibcryptsetup=disabled
      -Dlibcryptsetup-plugins=disabled
      -Dlibcurl=disabled
      -Dopenssl=disabled
      -Dzlib=disabled
      -Dbzip2=disabled
      -Dxz=disabled
      -Dlz4=disabled
      -Dzstd=disabled
      -Dpcre2=disabled
      -Dlibarchive=disabled
      -Dlibmount=disabled
      -Dfirstboot=false
      -Dinitrd=false
      -Dutmp=false
      -Dhibernate=false
      -Dldconfig=false
      -Dresolve=false
      -Defi=false
      -Dtpm=false
      -Denvironment-d=false
      -Dbinfmt=false
      -Drepart=disabled
      -Dsysupdate=disabled
      -Dsysupdated=disabled
      -Dcoredump=false
      -Dpstore=false
      -Doomd=false
      -Dlogind=false
      -Dhostnamed=false
      -Dlocaled=false
      -Dmachined=false
      -Dportabled=false
      -Dsysext=false
      -Dmountfsd=false
      -Duserdb=false
      -Dhomed=disabled
      -Dnetworkd=false
      -Dtimedated=false
      -Dtimesyncd=false
      -Dremote=disabled
      -Dcreate-log-dirs=false
      -Dnsresourced=false
      -Dnss-myhostname=false
      -Dnss-mymachines=disabled
      -Dnss-resolve=disabled
      -Dnss-systemd=false
      -Drandomseed=false
      -Dbacklight=false
      -Dvconsole=false
      -Dvmspawn=disabled
      -Dquotacheck=false
      -Dsysusers=false
      -Dtmpfiles=false
      -Dimportd=disabled
      -Dhwdb=false
      -Drfkill=false
      -Dstoragetm=false
      -Dxdg-autostart=false
      -Dnspawn=disabled
      -Dinstall-sysconfdir=false
      -Drpmmacrosdir=no
      -Dkernel-install=false
      -Dukify=disabled
      -Danalyze=false
      -Dmode=release
    )
  fi

  meson_install systemd "${DEP_SOURCE_DIR}/systemd" "${systemd_args[@]}"

  keep_libsystemd_sdk
}

build_libsystemd_autotools() {
  local package_build_dir="${DEP_BUILD_DIR}/systemd"

  rm -rf "$package_build_dir"
  mkdir -p "$package_build_dir"

  log "Configuring dependency: systemd ${SYSTEMD_VERSION}"
  (
    cd "$package_build_dir"
    env \
      CC="$CC" \
      LD="$LD" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR= \
      CPPFLAGS="${COMMON_CPPFLAGS}" \
      CFLAGS="${COMMON_CFLAGS}" \
      LDFLAGS="${COMMON_LDFLAGS}" \
      ac_cv_func_malloc_0_nonnull=yes \
      ac_cv_func_realloc_0_nonnull=yes \
      "${DEP_SOURCE_DIR}/systemd/configure" \
        --build="$CONFIGURE_BUILD_TRIPLE" \
        --host="$CONFIGURE_HOST_TRIPLE" \
        --prefix="$SDK_PREFIX" \
        --libdir="$SDK_PREFIX/lib" \
        --with-rootprefix="$SDK_PREFIX" \
        --with-rootlibdir="$SDK_PREFIX/lib" \
        --with-sysvinit-path= \
        --with-sysvrcnd-path= \
        --without-python \
        --disable-python-devel \
        --disable-nls \
        --disable-gtk-doc \
        --disable-manpages \
        --disable-tests \
        --disable-dbus \
        --disable-utmp \
        --disable-kmod \
        --disable-xkbcommon \
        --disable-blkid \
        --disable-seccomp \
        --disable-ima \
        --disable-chkconfig \
        --disable-selinux \
        --disable-apparmor \
        --disable-xz \
        --disable-zlib \
        --disable-bzip2 \
        --disable-lz4 \
        --disable-pam \
        --disable-acl \
        --disable-smack \
        --disable-gcrypt \
        --disable-audit \
        --disable-elfutils \
        --disable-libcryptsetup \
        --disable-qrencode \
        --disable-microhttpd \
        --disable-gnutls \
        --disable-libcurl \
        --disable-libidn \
        --disable-libiptc \
        --disable-binfmt \
        --disable-vconsole \
        --disable-bootchart \
        --disable-quotacheck \
        --disable-tmpfiles \
        --disable-sysusers \
        --disable-firstboot \
        --disable-randomseed \
        --disable-backlight \
        --disable-rfkill \
        --disable-logind \
        --disable-machined \
        --disable-importd \
        --disable-hostnamed \
        --disable-timedated \
        --disable-timesyncd \
        --disable-localed \
        --disable-coredump \
        --disable-polkit \
        --disable-resolved \
        --disable-networkd \
        --disable-efi \
        --disable-terminal \
        --disable-myhostname \
        --disable-gudev \
        --disable-hibernate \
        --disable-ldconfig

    log "Building dependency: systemd ${SYSTEMD_VERSION}"
    if [[ "$SYSTEMD_VERSION" == "219" ]]; then
      make -j "$JOBS" \
        src/shared/errno-from-name.h \
        src/shared/errno-to-name.h \
        src/shared/af-from-name.h \
        src/shared/af-to-name.h \
        src/shared/arphrd-from-name.h \
        src/shared/arphrd-to-name.h \
        src/shared/cap-from-name.h \
        src/shared/cap-to-name.h \
        src/libsystemd/libsystemd.sym
    fi
    make -j "$JOBS" libsystemd.la src/libsystemd/libsystemd.pc
  )

  mkdir -p "${SDK_PREFIX}/include" "${SDK_PREFIX}/lib/pkgconfig"
  cp -a "${package_build_dir}/.libs/libsystemd.so"* "${SDK_PREFIX}/lib/"
  cp -a "${DEP_SOURCE_DIR}/systemd/src/systemd" "${SDK_PREFIX}/include/"
  cp -a "${package_build_dir}/src/libsystemd/libsystemd.pc" "${SDK_PREFIX}/lib/pkgconfig/"

  keep_libsystemd_sdk
}

keep_linux_pam_sdk() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  find "${SDK_PREFIX}/lib" -maxdepth 1 -type f -name 'pam_*.so' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" -maxdepth 1 -type f \
    ! -name 'libpam.so' \
    ! -name 'libpam.so.*' \
    ! -name 'libpamc.so' \
    ! -name 'libpamc.so.*' \
    ! -name 'libpam_misc.so' \
    ! -name 'libpam_misc.so.*' \
    ! -name 'lib*.so' \
    ! -name 'lib*.so.*' \
    ! -name '*.dll.a' \
    -delete 2>/dev/null || true
  rm -rf \
    "${SDK_PREFIX}/etc/pam.d" \
    "${SDK_PREFIX}/lib/security" \
    "${SDK_PREFIX}/lib/security.d" \
    "${SDK_PREFIX}/sbin" \
    "${SDK_PREFIX}/share/pam" \
    "${SDK_PREFIX}/share/Linux-PAM" \
    "${SDK_PREFIX}/share/doc/Linux-PAM"
}

keep_libsystemd_sdk() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  find "${SDK_PREFIX}/bin" -mindepth 1 -maxdepth 1 ! -name '*-config' -delete 2>/dev/null || true
  find "${SDK_PREFIX}/lib" -maxdepth 1 -type f \
    ! -name 'libsystemd.so' \
    ! -name 'libsystemd.so.*' \
    ! -name 'libpam.so' \
    ! -name 'libpam.so.*' \
    ! -name 'libpamc.so' \
    ! -name 'libpamc.so.*' \
    ! -name 'libpam_misc.so' \
    ! -name 'libpam_misc.so.*' \
    ! -name 'lib*.so' \
    ! -name 'lib*.so.*' \
    ! -name '*.dll.a' \
    -delete 2>/dev/null || true
  rm -rf \
    "${SDK_PREFIX}/etc/systemd" \
    "${SDK_PREFIX}/lib/systemd" \
    "${SDK_PREFIX}/share/bash-completion" \
    "${SDK_PREFIX}/share/dbus-1" \
    "${SDK_PREFIX}/share/factory" \
    "${SDK_PREFIX}/share/man" \
    "${SDK_PREFIX}/share/polkit-1" \
    "${SDK_PREFIX}/share/systemd" \
    "${SDK_PREFIX}/var"
}

download_common_sources() {
  download_archive "$JSON_C_ARCHIVE_URL" "$JSON_C_ARCHIVE_NAME"
  download_archive "$LIBEVENT_ARCHIVE_URL" "$LIBEVENT_ARCHIVE_NAME"
}

download_linux_sources() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  download_archive "$KRB5_ARCHIVE_URL" "$KRB5_ARCHIVE_NAME"
  download_archive "$CYRUS_SASL_ARCHIVE_URL" "$CYRUS_SASL_ARCHIVE_NAME"
  download_archive "$OPENLDAP_ARCHIVE_URL" "$OPENLDAP_ARCHIVE_NAME"
  download_archive "$KEYUTILS_ARCHIVE_URL" "$KEYUTILS_ARCHIVE_NAME"
  download_archive "$LIBXCRYPT_ARCHIVE_URL" "$LIBXCRYPT_ARCHIVE_NAME"
  download_archive "$LIBURING_ARCHIVE_URL" "$LIBURING_ARCHIVE_NAME"
  download_archive "$LINUX_PAM_ARCHIVE_URL" "$LINUX_PAM_ARCHIVE_NAME"
  download_archive "$LIBCAP_ARCHIVE_URL" "$LIBCAP_ARCHIVE_NAME"
  download_archive "$UTIL_LINUX_ARCHIVE_URL" "$UTIL_LINUX_ARCHIVE_NAME"
  download_archive "$SYSTEMD_ARCHIVE_URL" "$SYSTEMD_ARCHIVE_NAME"
  download_archive "$GPERF_ARCHIVE_URL" "$GPERF_ARCHIVE_NAME"
  download_archive "$JINJA2_ARCHIVE_URL" "$JINJA2_ARCHIVE_NAME"
  download_archive "$MARKUPSAFE_ARCHIVE_URL" "$MARKUPSAFE_ARCHIVE_NAME"
}

extract_common_sources() {
  extract_archive_source "${DEP_SOURCE_DIR}/json-c" "$JSON_C_ARCHIVE_NAME" "CMakeLists.txt"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch_once "${DEP_SOURCE_DIR}/json-c" "${PATCH_DIR}/json-c-mingw-no-elf-linker-flags.patch"
  fi
  extract_archive_source "${DEP_SOURCE_DIR}/libevent" "$LIBEVENT_ARCHIVE_NAME" "CMakeLists.txt"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    apply_source_patch_once "${DEP_SOURCE_DIR}/libevent" "${PATCH_DIR}/libevent-mingw-win32-winnt.patch"
  fi
}

extract_linux_sources() {
  [[ "$TARGET_KIND" == "linux" ]] || return 0

  extract_archive_source "${DEP_SOURCE_DIR}/krb5" "$KRB5_ARCHIVE_NAME" "src/configure"
  extract_archive_source "${DEP_SOURCE_DIR}/cyrus-sasl" "$CYRUS_SASL_ARCHIVE_NAME" "configure"
  extract_archive_source "${DEP_SOURCE_DIR}/openldap" "$OPENLDAP_ARCHIVE_NAME" "configure"
  extract_archive_source "${DEP_SOURCE_DIR}/keyutils" "$KEYUTILS_ARCHIVE_NAME" "Makefile"
  extract_archive_source "${DEP_SOURCE_DIR}/libxcrypt" "$LIBXCRYPT_ARCHIVE_NAME" "configure"
  extract_archive_source "${DEP_SOURCE_DIR}/liburing" "$LIBURING_ARCHIVE_NAME" "configure"
  extract_archive_source "${DEP_SOURCE_DIR}/linux-pam" "$LINUX_PAM_ARCHIVE_NAME" "meson.build"
  extract_archive_source "${DEP_SOURCE_DIR}/libcap" "$LIBCAP_ARCHIVE_NAME" "libcap/Makefile"
  extract_archive_source "${DEP_SOURCE_DIR}/util-linux" "$UTIL_LINUX_ARCHIVE_NAME" "configure"
  if [[ "$SYSTEMD_BUILD_SYSTEM" == "autotools" ]]; then
    extract_archive_source "${DEP_SOURCE_DIR}/systemd" "$SYSTEMD_ARCHIVE_NAME" "configure"
    if [[ "$SYSTEMD_VERSION" == "219" ]]; then
      apply_source_patch_once "${DEP_SOURCE_DIR}/systemd" "${PATCH_DIR}/systemd-219-clang-cmsg-space.patch"
      apply_source_patch_once "${DEP_SOURCE_DIR}/systemd" "${PATCH_DIR}/systemd-219-gperf-size-t.patch"
    fi
  else
    extract_archive_source "${DEP_SOURCE_DIR}/systemd" "$SYSTEMD_ARCHIVE_NAME" "meson.build"
    if [[ "$SYSTEMD_VERSION" != "241" ]]; then
      apply_source_patch_once "${DEP_SOURCE_DIR}/systemd" "${PATCH_DIR}/systemd-old-linux-sdk-headers.patch"
    fi
  fi
  extract_archive_source "${DEP_SOURCE_DIR}/gperf" "$GPERF_ARCHIVE_NAME" "configure"
  extract_archive_source "${DEP_SOURCE_DIR}/jinja2" "$JINJA2_ARCHIVE_NAME" "src/jinja2/__init__.py"
  extract_archive_source "${DEP_SOURCE_DIR}/markupsafe" "$MARKUPSAFE_ARCHIVE_NAME" "src/markupsafe/__init__.py"
}

build_linux_dependencies() {
  build_keyutils
  build_json_c
  build_libevent
  build_libxcrypt
  build_liburing
  build_krb5
  build_cyrus_sasl
  build_openldap
  build_linux_pam
  build_libcap
  build_util_linux_libmount
  build_native_gperf
  build_python_jinja2
  build_libsystemd
}

build_mingw_dependencies() {
  build_json_c
  build_libevent
}

build_target_dependencies() {
  case "$TARGET_KIND" in
    linux)
      build_linux_dependencies
      ;;
    mingw)
      log "Using MinGW PostgreSQL dependency subset"
      build_mingw_dependencies
      ;;
    *)
      die "unsupported TARGET_KIND: ${TARGET_KIND}"
      ;;
  esac
}

require_path() {
  local path="$1"
  [[ -e "$path" ]] || die "missing required dependency artifact: $path"
}

require_glob() {
  local pattern="$1"
  compgen -G "$pattern" >/dev/null || die "missing required dependency artifact: $pattern"
}

validate_dynamic_libraries() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    require_glob "${SDK_PREFIX}/bin/libjson-c*.dll"
    require_glob "${SDK_PREFIX}/bin/libevent*.dll"
  else
    require_path "${SDK_PREFIX}/lib/libkrb5.so"
    require_path "${SDK_PREFIX}/lib/libkeyutils.so"
    require_path "${SDK_PREFIX}/lib/libsasl2.so"
    require_path "${SDK_PREFIX}/lib/libldap.so"
    require_path "${SDK_PREFIX}/lib/libjson-c.so"
    require_path "${SDK_PREFIX}/lib/libcrypt.so"
    require_path "${SDK_PREFIX}/lib/libevent.so"
    require_path "${SDK_PREFIX}/lib/liburing.so"
    require_path "${SDK_PREFIX}/lib/libpam.so"
    require_path "${SDK_PREFIX}/lib/libcap.so"
    require_path "${SDK_PREFIX}/lib/libblkid.so"
    require_path "${SDK_PREFIX}/lib/libmount.so"
    require_path "${SDK_PREFIX}/lib/libsystemd.so"
  fi
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/postgresql_dependencies-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"

KRB5_VERSION="${KRB5_VERSION:-1.22.2}"
KEYUTILS_VERSION="${KEYUTILS_VERSION:-1.6.1}"
CYRUS_SASL_VERSION="${CYRUS_SASL_VERSION:-2.1.28}"
OPENLDAP_VERSION="${OPENLDAP_VERSION:-2.6.13}"
JSON_C_VERSION="${JSON_C_VERSION:-0.18-20240915}"
LIBXCRYPT_VERSION="${LIBXCRYPT_VERSION:-4.5.2}"
LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12-stable}"
LIBURING_VERSION="${LIBURING_VERSION:-2.14}"
LINUX_PAM_VERSION="${LINUX_PAM_VERSION:-1.7.2}"
LIBCAP_VERSION="${LIBCAP_VERSION:-2.76}"
UTIL_LINUX_VERSION="${UTIL_LINUX_VERSION:-2.42}"
case "${TARGET_TRIPLE:-}" in
  x86_64-unknown-linux-gnu)
    SYSTEMD_VERSION="${SYSTEMD_VERSION:-219}"
    SYSTEMD_BUILD_SYSTEM="${SYSTEMD_BUILD_SYSTEM:-autotools}"
    SYSTEMD_PACKAGE_VERSION="${SYSTEMD_PACKAGE_VERSION:-CentOS 7 systemd 219}"
    ;;
  aarch64-unknown-linux-gnu)
    SYSTEMD_VERSION="${SYSTEMD_VERSION:-241}"
    SYSTEMD_BUILD_SYSTEM="${SYSTEMD_BUILD_SYSTEM:-meson}"
    SYSTEMD_PACKAGE_VERSION="${SYSTEMD_PACKAGE_VERSION:-Debian 10 systemd 241}"
    ;;
  *)
    SYSTEMD_VERSION="${SYSTEMD_VERSION:-260.1}"
    SYSTEMD_BUILD_SYSTEM="${SYSTEMD_BUILD_SYSTEM:-meson}"
    SYSTEMD_PACKAGE_VERSION="${SYSTEMD_PACKAGE_VERSION:-systemd ${SYSTEMD_VERSION}}"
    ;;
esac
GPERF_VERSION="${GPERF_VERSION:-3.3}"
JINJA2_VERSION="${JINJA2_VERSION:-3.1.6}"
MARKUPSAFE_VERSION="${MARKUPSAFE_VERSION:-3.0.3}"

KRB5_ARCHIVE_NAME="krb5-${KRB5_VERSION}.tar.gz"
KEYUTILS_ARCHIVE_NAME="keyutils-${KEYUTILS_VERSION}.tar.bz2"
CYRUS_SASL_ARCHIVE_NAME="cyrus-sasl-${CYRUS_SASL_VERSION}.tar.gz"
OPENLDAP_ARCHIVE_NAME="openldap-${OPENLDAP_VERSION}.tgz"
JSON_C_ARCHIVE_NAME="json-c-${JSON_C_VERSION}.tar.gz"
LIBXCRYPT_ARCHIVE_NAME="libxcrypt-${LIBXCRYPT_VERSION}.tar.xz"
LIBEVENT_ARCHIVE_NAME="libevent-${LIBEVENT_VERSION}.tar.gz"
LIBURING_ARCHIVE_NAME="liburing-${LIBURING_VERSION}.tar.gz"
LINUX_PAM_ARCHIVE_NAME="Linux-PAM-${LINUX_PAM_VERSION}.tar.xz"
LIBCAP_ARCHIVE_NAME="libcap-${LIBCAP_VERSION}.tar.xz"
UTIL_LINUX_ARCHIVE_NAME="util-linux-${UTIL_LINUX_VERSION}.tar.xz"
if [[ "$SYSTEMD_BUILD_SYSTEM" == "autotools" ]]; then
  SYSTEMD_ARCHIVE_NAME="systemd-${SYSTEMD_VERSION}.tar.xz"
else
  SYSTEMD_ARCHIVE_NAME="systemd-${SYSTEMD_VERSION}.tar.gz"
fi
GPERF_ARCHIVE_NAME="gperf-${GPERF_VERSION}.tar.gz"
JINJA2_ARCHIVE_NAME="jinja2-${JINJA2_VERSION}.tar.gz"
MARKUPSAFE_ARCHIVE_NAME="markupsafe-${MARKUPSAFE_VERSION}.tar.gz"

KRB5_ARCHIVE_URL="${KRB5_ARCHIVE_URL:-https://kerberos.org/dist/krb5/${KRB5_VERSION%.*}/${KRB5_ARCHIVE_NAME}}"
KEYUTILS_ARCHIVE_URL="${KEYUTILS_ARCHIVE_URL:-https://people.redhat.com/dhowells/keyutils/${KEYUTILS_ARCHIVE_NAME}}"
CYRUS_SASL_ARCHIVE_URL="${CYRUS_SASL_ARCHIVE_URL:-https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-${CYRUS_SASL_VERSION}/${CYRUS_SASL_ARCHIVE_NAME}}"
OPENLDAP_ARCHIVE_URL="${OPENLDAP_ARCHIVE_URL:-https://www.openldap.org/software/download/OpenLDAP/openldap-release/${OPENLDAP_ARCHIVE_NAME}}"
JSON_C_ARCHIVE_URL="${JSON_C_ARCHIVE_URL:-https://github.com/json-c/json-c/archive/refs/tags/json-c-${JSON_C_VERSION}.tar.gz}"
LIBXCRYPT_ARCHIVE_URL="${LIBXCRYPT_ARCHIVE_URL:-https://github.com/besser82/libxcrypt/releases/download/v${LIBXCRYPT_VERSION}/${LIBXCRYPT_ARCHIVE_NAME}}"
LIBEVENT_ARCHIVE_URL="${LIBEVENT_ARCHIVE_URL:-https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/${LIBEVENT_ARCHIVE_NAME}}"
LIBURING_ARCHIVE_URL="${LIBURING_ARCHIVE_URL:-https://github.com/axboe/liburing/archive/refs/tags/${LIBURING_ARCHIVE_NAME}}"
LINUX_PAM_ARCHIVE_URL="${LINUX_PAM_ARCHIVE_URL:-https://github.com/linux-pam/linux-pam/releases/download/v${LINUX_PAM_VERSION}/${LINUX_PAM_ARCHIVE_NAME}}"
LIBCAP_ARCHIVE_URL="${LIBCAP_ARCHIVE_URL:-https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/${LIBCAP_ARCHIVE_NAME}}"
UTIL_LINUX_ARCHIVE_URL="${UTIL_LINUX_ARCHIVE_URL:-https://www.kernel.org/pub/linux/utils/util-linux/v${UTIL_LINUX_VERSION}/${UTIL_LINUX_ARCHIVE_NAME}}"
if [[ "$SYSTEMD_BUILD_SYSTEM" == "autotools" ]]; then
  SYSTEMD_ARCHIVE_URL="${SYSTEMD_ARCHIVE_URL:-https://www.freedesktop.org/software/systemd/${SYSTEMD_ARCHIVE_NAME}}"
else
  SYSTEMD_ARCHIVE_URL="${SYSTEMD_ARCHIVE_URL:-https://github.com/systemd/systemd/archive/refs/tags/v${SYSTEMD_VERSION}.tar.gz}"
fi
GPERF_ARCHIVE_URL="${GPERF_ARCHIVE_URL:-https://ftp.gnu.org/pub/gnu/gperf/${GPERF_ARCHIVE_NAME}}"
JINJA2_ARCHIVE_URL="${JINJA2_ARCHIVE_URL:-https://files.pythonhosted.org/packages/source/j/jinja2/${JINJA2_ARCHIVE_NAME}}"
MARKUPSAFE_ARCHIVE_URL="${MARKUPSAFE_ARCHIVE_URL:-https://files.pythonhosted.org/packages/source/m/markupsafe/${MARKUPSAFE_ARCHIVE_NAME}}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing base dependency prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make
require_command cmake
require_command ninja
require_command patch
require_command pkg-config

case "$TARGET_KIND" in
  linux)
    CMAKE_SYSTEM_NAME="Linux"
    CMAKE_SYSTEM_PROCESSOR="$ARCH"
    MESON_SYSTEM="linux"
    MESON_CPU_FAMILY="$ARCH"
    MESON_CPU="$ARCH"
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    EXEEXT=""
    require_command meson
    ;;
  mingw)
    CMAKE_SYSTEM_NAME="Windows"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    MESON_SYSTEM="windows"
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-x86_64-w64-mingw32}"
    EXEEXT=".exe"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac

[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TRIPLE="$("${LLVM_ROOT}/bin/clang" -dumpmachine 2>/dev/null || echo x86_64-unknown-linux-gnu)"
CONFIGURE_BUILD_TRIPLE="${CONFIGURE_BUILD_TRIPLE:-$BUILD_TRIPLE}"
if [[ "$CONFIGURE_BUILD_TRIPLE" == "$CONFIGURE_HOST_TRIPLE" ]]; then
  CONFIGURE_BUILD_TRIPLE="${ARCH}-postgresqldepsbuild-linux-gnu"
fi

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
BUILD_CXX="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"

CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
LD="${LD:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ld}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-objcopy}"
RC="${RC:-${LLVM_ROOT}/bin/llvm-windres}"
OBJDUMP="${OBJDUMP:-${LLVM_ROOT}/bin/llvm-objdump}"
DLLTOOL="${DLLTOOL:-${LLVM_ROOT}/bin/llvm-dlltool}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$LD" ]] || LD="${LLVM_ROOT}/bin/ld.lld"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$OBJCOPY" ]] || OBJCOPY="${LLVM_ROOT}/bin/llvm-objcopy"
[[ -x "$RC" ]] || RC="${LLVM_ROOT}/bin/llvm-rc"
[[ -x "$OBJDUMP" ]] || OBJDUMP="${LLVM_ROOT}/bin/llvm-objdump"
[[ -x "$DLLTOOL" ]] || DLLTOOL="${LLVM_ROOT}/bin/llvm-dlltool"

DEP_SOURCE_DIR="${BUILD_DIR}/deps-source"
DEP_BUILD_DIR="${BUILD_DIR}/deps-build"
BUILD_TOOLS="${BUILD_DIR}/tools"
BUILD_COMPAT_INCLUDE="${BUILD_DIR}/compat-include"
TOOLCHAIN_FILE="${BUILD_DIR}/postgresql-deps-toolchain.cmake"
MESON_CROSS_FILE="${BUILD_DIR}/postgresql-deps-meson-cross.ini"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"

mkdir -p "$DEP_SOURCE_DIR" "$DEP_BUILD_DIR" "$BUILD_TOOLS"
write_realpath_wrapper
write_printf_wrapper
write_ln_wrapper
write_rsync_wrapper
prepare_linux_compat_headers

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "${LLVM_ROOT}/bin/clang"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-cc"
fi
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx" "${LLVM_ROOT}/bin/clang++"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx"
fi
if [[ "$TARGET_KIND" == "mingw" ]]; then
  write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "$RC"
  RC="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
fi

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/ncursesw"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi
MESON_EXTRA_C_ARGS="${MESON_EXTRA_C_ARGS:-$(linux_syscall_meson_c_args)}"
RC_FLAGS="${RC_FLAGS:-}"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  RC_FLAGS="-I${SYSROOT}/usr/${TARGET_TRIPLE}/include -I${TARGET_ROOT}/include ${RC_FLAGS}"
fi

export PATH="${BUILD_TOOLS}:${PATH}"
export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=

write_toolchain_file
write_meson_cross_file
rewrite_dependency_prefixes

download_common_sources
download_linux_sources
extract_common_sources
extract_linux_sources

log "Installing PostgreSQL dependencies into ${SDK_PREFIX}"
build_target_dependencies

rewrite_dependency_prefixes
copy_dependency_dlls_to_bin
remove_static_libraries
remove_unneeded_docs
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_dynamic_libraries

render_template "${TEMPLATE_DIR}/README.postgresql-dependencies.in" "${SDK_PREFIX}/README.postgresql-dependencies" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "KRB5_VERSION=${KRB5_VERSION}" \
  "KEYUTILS_VERSION=${KEYUTILS_VERSION}" \
  "CYRUS_SASL_VERSION=${CYRUS_SASL_VERSION}" \
  "OPENLDAP_VERSION=${OPENLDAP_VERSION}" \
  "JSON_C_VERSION=${JSON_C_VERSION}" \
  "LIBXCRYPT_VERSION=${LIBXCRYPT_VERSION}" \
  "LIBEVENT_VERSION=${LIBEVENT_VERSION}" \
  "LIBURING_VERSION=${LIBURING_VERSION}" \
  "LINUX_PAM_VERSION=${LINUX_PAM_VERSION}" \
  "SYSTEMD_VERSION=${SYSTEMD_PACKAGE_VERSION}"

log "PostgreSQL dependencies ready: ${SDK_PREFIX}"
