#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

apply_source_patch_once() {
  local source_dir="$1"
  local patch_path="$2"
  local patch_name=""

  patch_name="$(basename "$patch_path")"
  if [[ ! -f "${source_dir}/.patched-${patch_name}" ]]; then
    (
      cd "$source_dir"
      patch -p1 -i "$patch_path"
    )
    touch "${source_dir}/.patched-${patch_name}"
  fi
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
  local archive_path="$2"
  local marker_path="$3"
  local archive_name=""
  local archive_marker="${source_dir}/.source-archive"

  archive_name="$(basename "$archive_path")"
  if [[ ! -e "${source_dir}/${marker_path}" ]] \
      || [[ ! -f "$archive_marker" ]] \
      || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar -xf "$archive_path" -C "$source_dir" --strip-components=1
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  [[ -e "${source_dir}/${marker_path}" ]] || die "invalid source tree: ${source_dir}"
}

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"

  cat >"$wrapper_path" <<EOF
#!/bin/sh
exec "${real_compiler}" --target="${TARGET_TRIPLE}" --sysroot="${SYSROOT}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_exec_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  cat >"$wrapper_path" <<EOF
#!/bin/sh
exec "${real_tool}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_target_runner_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

exec ${POSTGRESQL_TARGET_RUNNER} "${real_tool}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_windres_wrapper() {
  local wrapper_path="$1"
  local real_windres="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

exec "${real_windres}" \
  --target="${TARGET_TRIPLE}" \
  -I"${SYSROOT}/usr/${TARGET_TRIPLE}/include" \
  -I"${TARGET_ROOT}/include" \
  "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_meson_cross_file() {
  render_template "${TEMPLATE_DIR}/meson-cross.ini.in" "$MESON_CROSS_FILE" \
    "CC=${CC}" \
    "CXX=${CXX}" \
    "AR=${AR}" \
    "STRIP=${STRIP}" \
    "SYSROOT=${SYSROOT}" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "MESON_SYSTEM=${MESON_SYSTEM}" \
    "MESON_CPU_FAMILY=${MESON_CPU_FAMILY}" \
    "MESON_CPU=${MESON_CPU}" \
    "MESON_EXTRA_C_ARGS=${MESON_EXTRA_C_ARGS}" \
    "MESON_EXTRA_LINK_ARGS=${MESON_EXTRA_LINK_ARGS}"
}

write_runtime_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"
  local extra_exports="${3:-}"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export LD_LIBRARY_PATH="${SDK_PREFIX}/lib:\${LD_LIBRARY_PATH:-}"
${extra_exports}
if [[ -n "${POSTGRESQL_TARGET_RUNNER}" ]]; then
  exec ${POSTGRESQL_TARGET_RUNNER} "${real_tool}" "\$@"
fi
exec "${real_tool}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

rewrite_dependency_prefixes() {
  local installed_file=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac

    if grep -IqF "/opt/postgresql_dependencies" "$installed_file"; then
      sed -E -i \
        "s#/opt/postgresql_dependencies[^\"'[:space:]]*${TARGET_TRIPLE}#${SDK_PREFIX}#g" \
        "$installed_file"
    fi
  done < <(
    find "$SDK_PREFIX" -type f -print0 2>/dev/null
  )
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete
  find "${SDK_PREFIX}/lib" -type f -name '*.a' \
    ! -name '*.dll.a' \
    -delete
}

remove_postgresql_docs() {
  rm -rf "${SDK_PREFIX}/share/doc/postgresql" \
         "${SDK_PREFIX}/share/doc/postgresql-${POSTGRESQL_VERSION}" \
         "${SDK_PREFIX}/doc"
}

postgresql_archive_url() {
  printf '%s\n' "${POSTGRESQL_ARCHIVE_URL:-https://ftp.postgresql.org/pub/source/v${POSTGRESQL_VERSION}/${POSTGRESQL_ARCHIVE_NAME}}"
}

find_runtime_executable() {
  local tool_name="$1"

  if [[ -x "${SDK_PREFIX}/bin/${tool_name}${EXEEXT}" ]]; then
    printf '%s\n' "${SDK_PREFIX}/bin/${tool_name}${EXEEXT}"
    return 0
  fi
  if [[ -x "${SDK_PREFIX}/bin/${tool_name}" ]]; then
    printf '%s\n' "${SDK_PREFIX}/bin/${tool_name}"
    return 0
  fi

  return 1
}

detect_optional_language_support() {
  ENABLE_PERL=0
  ENABLE_PYTHON=0
  ENABLE_TCL=0
  PERL_PRIVLIB_DIR=""
  PERL_ARCHLIB_DIR=""
  PERL_CORE_DIR=""
  PERL_PREFIX_DIR=""
  PERL_BIN=""
  PERL_CONFIG_QUERY_BIN=""
  PYTHON_PREFIX_DIR=""
  PYTHON_INCLUDE_DIR=""
  PYTHON_BIN=""
  PYTHON_CONFIG_QUERY_BIN=""
  TCLSH_BIN=""
  TCL_CONFIG_QUERY_BIN=""

  if PERL_BIN="$(find_runtime_executable perl 2>/dev/null)"; then
    ENABLE_PERL=1
    if [[ -d "${SDK_PREFIX}/lib" ]]; then
      PERL_ARCHLIB_DIR="$(
        find "${SDK_PREFIX}/lib" -path '*/Config_heavy.pl' -type f -print 2>/dev/null \
          | sort \
          | head -n 1
      )"
      if [[ -n "${PERL_ARCHLIB_DIR}" ]]; then
        PERL_ARCHLIB_DIR="$(dirname "${PERL_ARCHLIB_DIR}")"
        PERL_PRIVLIB_DIR="$(dirname "${PERL_ARCHLIB_DIR}")"
        if [[ -d "${PERL_ARCHLIB_DIR}/CORE" ]]; then
          PERL_CORE_DIR="${PERL_ARCHLIB_DIR}/CORE"
        fi
      fi
    fi
  fi

  if PYTHON_BIN="$(find_runtime_executable python3 2>/dev/null)"; then
    ENABLE_PYTHON=1
  elif PYTHON_BIN="$(find_runtime_executable python 2>/dev/null)"; then
    ENABLE_PYTHON=1
  else
    PYTHON_BIN="$(find "${SDK_PREFIX}/bin" -maxdepth 1 -type f \( -name 'python3.[0-9]*' -o -name 'python[0-9].[0-9]*' -o -name 'python3.[0-9]*.exe' -o -name 'python[0-9].[0-9]*.exe' \) | sort | head -n 1 || true)"
    if [[ -n "${PYTHON_BIN}" && -x "${PYTHON_BIN}" ]]; then
      ENABLE_PYTHON=1
    fi
  fi
  if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
    PYTHON_INCLUDE_DIR="$(
      find "${SDK_PREFIX}/include" -path '*/Python.h' -type f -print 2>/dev/null \
        | sort \
        | head -n 1
    )"
    if [[ -n "$PYTHON_INCLUDE_DIR" ]]; then
      PYTHON_INCLUDE_DIR="$(dirname "$PYTHON_INCLUDE_DIR")"
    fi
  fi

  if TCLSH_BIN="$(find_runtime_executable tclsh 2>/dev/null)"; then
    ENABLE_TCL=1
  else
    TCLSH_BIN="$(find "${SDK_PREFIX}/bin" -maxdepth 1 -type f \( -name 'tclsh*' -o -name 'tclsh*.exe' \) | sort | head -n 1 || true)"
    if [[ -n "${TCLSH_BIN}" && -x "${TCLSH_BIN}" ]]; then
      ENABLE_TCL=1
    fi
  fi

  PERL_CONFIG_QUERY_BIN="$PERL_BIN"
  PYTHON_CONFIG_QUERY_BIN="$PYTHON_BIN"
  TCL_CONFIG_QUERY_BIN="$TCLSH_BIN"

  if [[ -n "$POSTGRESQL_TARGET_RUNNER" ]]; then
    if [[ "$ENABLE_PERL" -eq 1 ]]; then
      PERL_CONFIG_QUERY_BIN="${BUILD_TOOLS}/target-perl-config"
      write_target_runner_wrapper "$PERL_CONFIG_QUERY_BIN" "$PERL_BIN"
      if [[ -n "$PERL_ARCHLIB_DIR" && -n "$PERL_PRIVLIB_DIR" ]]; then
        PERL_PREFIX_DIR="$(
          PERL5LIB="${PERL_ARCHLIB_DIR}:${PERL_PRIVLIB_DIR}" \
            "$PERL_CONFIG_QUERY_BIN" -MConfig -e 'print $Config{prefix}' 2>/dev/null || true
        )"
      elif [[ -n "$PERL_ARCHLIB_DIR" ]]; then
        PERL_PREFIX_DIR="$(dirname "$(dirname "$PERL_ARCHLIB_DIR")")"
      fi
    fi

    if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
      PYTHON_CONFIG_QUERY_BIN="${BUILD_TOOLS}/target-python-config"
      write_target_runner_wrapper "$PYTHON_CONFIG_QUERY_BIN" "$PYTHON_BIN"
      PYTHON_PREFIX_DIR="$("$PYTHON_CONFIG_QUERY_BIN" -c 'import sys; print(sys.base_prefix)' 2>/dev/null || true)"
      if [[ -z "$PYTHON_PREFIX_DIR" || "$PYTHON_PREFIX_DIR" == "$SDK_PREFIX" ]]; then
        PYTHON_PREFIX_DIR="$("$PYTHON_CONFIG_QUERY_BIN" -c 'import sysconfig; print((sysconfig.get_config_var("INCLUDEPY") or "").rsplit("/include/", 1)[0])' 2>/dev/null || true)"
      fi
    fi

    if [[ "$ENABLE_TCL" -eq 1 ]]; then
      TCL_CONFIG_QUERY_BIN="${BUILD_TOOLS}/target-tclsh-config"
      write_target_runner_wrapper "$TCL_CONFIG_QUERY_BIN" "$TCLSH_BIN"
    fi
  else
    if [[ "$ENABLE_PERL" -eq 1 && -n "$PERL_ARCHLIB_DIR" && -n "$PERL_PRIVLIB_DIR" ]]; then
      PERL_PREFIX_DIR="$(
        PERL5LIB="${PERL_ARCHLIB_DIR}:${PERL_PRIVLIB_DIR}" \
          "$PERL_CONFIG_QUERY_BIN" -MConfig -e 'print $Config{prefix}' 2>/dev/null || true
      )"
    elif [[ "$ENABLE_PERL" -eq 1 && -n "$PERL_ARCHLIB_DIR" ]]; then
      PERL_PREFIX_DIR="$(dirname "$(dirname "$PERL_ARCHLIB_DIR")")"
    fi

    if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
      PYTHON_PREFIX_DIR="$("$PYTHON_CONFIG_QUERY_BIN" -c 'import sys; print(sys.base_prefix)' 2>/dev/null || true)"
      if [[ -z "$PYTHON_PREFIX_DIR" || "$PYTHON_PREFIX_DIR" == "$SDK_PREFIX" ]]; then
        PYTHON_PREFIX_DIR="$("$PYTHON_CONFIG_QUERY_BIN" -c 'import sysconfig; print((sysconfig.get_config_var("INCLUDEPY") or "").rsplit("/include/", 1)[0])' 2>/dev/null || true)"
      fi
    fi
  fi

  if [[ "$ENABLE_PYTHON" -eq 1 && ( -z "$PYTHON_PREFIX_DIR" || "$PYTHON_PREFIX_DIR" == "$SDK_PREFIX" ) ]]; then
    local python_pc=""
    python_pc="$(
      find "${SDK_PREFIX}/lib/pkgconfig" -maxdepth 1 -type f -name 'python-*.pc' ! -name '*-embed.pc' -print 2>/dev/null \
        | sort \
        | head -n 1
    )"
    if [[ -n "$python_pc" ]]; then
      PYTHON_PREFIX_DIR="$(sed -n 's/^prefix=//p' "$python_pc" | head -n 1)"
    fi
  fi

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    ENABLE_PERL=0
    ENABLE_PYTHON=0
    PERL_PRIVLIB_DIR=""
    PERL_ARCHLIB_DIR=""
    PERL_CORE_DIR=""
    PERL_PREFIX_DIR=""
    PERL_BIN=""
    PERL_CONFIG_QUERY_BIN=""
    PYTHON_PREFIX_DIR=""
    PYTHON_INCLUDE_DIR=""
    PYTHON_BIN=""
    PYTHON_CONFIG_QUERY_BIN=""
    log "Disabling PL/Perl and PL/Python for mingw64 builds"
  fi
}

ensure_perl_prefix_alias() {
  [[ "$ENABLE_PERL" -eq 1 ]] || return 0
  [[ -n "$PERL_PREFIX_DIR" ]] || return 0
  [[ "$PERL_PREFIX_DIR" == "$SDK_PREFIX" ]] && return 0
  [[ "$PERL_PREFIX_DIR" == /opt/* ]] || return 0

  if [[ ! -e "$PERL_PREFIX_DIR" ]]; then
    mkdir -p "$(dirname "$PERL_PREFIX_DIR")"
    ln -s "$SDK_PREFIX" "$PERL_PREFIX_DIR"
  fi
}

ensure_python_prefix_alias() {
  [[ "$ENABLE_PYTHON" -eq 1 ]] || return 0
  [[ -n "$PYTHON_PREFIX_DIR" ]] || return 0
  [[ "$PYTHON_PREFIX_DIR" == "$SDK_PREFIX" ]] && return 0
  [[ "$PYTHON_PREFIX_DIR" == /opt/* ]] || return 0

  if [[ ! -e "$PYTHON_PREFIX_DIR" ]]; then
    mkdir -p "$(dirname "$PYTHON_PREFIX_DIR")"
    ln -s "$SDK_PREFIX" "$PYTHON_PREFIX_DIR"
  fi
}

copy_system_tzdata_into_prefix() {
  [[ "$COPY_SYSTEM_TZDATA" -eq 1 ]] || return 0

  log "Copying system timezone database into package prefix"
  rm -rf "${SYSTEM_TZDATA_DIR}"
  mkdir -p "$(dirname "${SYSTEM_TZDATA_DIR}")"
  cp -a /usr/share/zoneinfo "${SYSTEM_TZDATA_DIR}"
}

prepare_meson_runtime_wrappers() {
  PERL_MESON_BIN=""
  PYTHON_MESON_BIN=""

  if [[ "$ENABLE_PERL" -eq 1 ]]; then
    PERL_MESON_BIN="${BUILD_TOOLS}/perl"
    write_runtime_wrapper \
      "$PERL_MESON_BIN" \
      "$PERL_BIN" \
      "export PERL5LIB=\"${PERL_ARCHLIB_DIR}:${PERL_PRIVLIB_DIR}\""
  fi

  if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
    PYTHON_MESON_BIN="${BUILD_TOOLS}/python3"
    write_runtime_wrapper \
      "$PYTHON_MESON_BIN" \
      "$PYTHON_BIN" \
      "export PYTHONHOME=\"${SDK_PREFIX}\""
    ln -sfn "$(basename "$PYTHON_MESON_BIN")" "${BUILD_TOOLS}/python"
  fi
}

build_postgresql_meson() {
  local meson_args=()
  local stage_dir="${POSTGRESQL_BUILD_DIR}/stage"

  detect_optional_language_support
  ensure_perl_prefix_alias
  ensure_python_prefix_alias
  rewrite_dependency_prefixes

  rm -rf "$POSTGRESQL_BUILD_DIR"
  mkdir -p "$POSTGRESQL_BUILD_DIR"

  write_meson_cross_file
  prepare_meson_runtime_wrappers

  meson_args=(
    --cross-file="$MESON_CROSS_FILE"
    --prefix="$SDK_PREFIX"
    --bindir=bin
    --libdir=lib
    --includedir=include
    --datadir=share
    --localedir=share/locale
    --sysconfdir=etc
    --buildtype=release
    --wrap-mode=nofallback
    -Ddocs=disabled
    -Ddocs_pdf=disabled
    -Dnls=disabled
    -Dtap_tests=disabled
    -Dbonjour=disabled
    -Dbsd_auth=disabled
    -Ddtrace=disabled
    -Dselinux=disabled
    -Dsystem_tzdata="${SYSTEM_TZDATA_DIR}"
  )

  case "$TARGET_KIND" in
    linux)
      meson_args+=(
        -Dicu=enabled
        -Dldap=enabled
        -Dssl=openssl
        -Dlibnuma=enabled
        -Dliburing=enabled
        -Dpam=enabled
        -Dlibxml=enabled
        -Dlibxslt=enabled
        -Dgssapi=enabled
        -Dzlib=enabled
        -Dreadline=enabled
        -Dlz4=enabled
        -Dzstd=enabled
        -Dsystemd=enabled
        -Duuid=e2fs
      )
      ;;
    mingw)
      meson_args+=(
        -Dicu=enabled
        -Dssl=openssl
        -Dlibxml=enabled
        -Dlibxslt=enabled
        -Dzlib=enabled
        -Dreadline=disabled
        -Dlz4=enabled
        -Dzstd=enabled
        -Duuid=none
      )
      ;;
    *)
      die "unsupported TARGET_KIND: ${TARGET_KIND}"
      ;;
  esac

  if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" && -x "${LLVM_ROOT}/bin/llvm-config" ]]; then
    meson_args+=(-Dllvm=enabled)
  else
    meson_args+=(-Dllvm=disabled)
  fi

  if [[ "$ENABLE_PERL" -eq 1 ]]; then
    meson_args+=(-Dplperl=enabled -DPERL=perl)
  else
    meson_args+=(-Dplperl=disabled)
    log "Perl runtime prefix not found; building without PL/Perl"
  fi

  if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
    meson_args+=(-Dplpython=enabled -DPYTHON=python3)
  else
    meson_args+=(-Dplpython=disabled)
    log "Python runtime prefix not found; building without PL/Python"
  fi

  if [[ "$ENABLE_TCL" -eq 1 ]]; then
    meson_args+=(-Dpltcl=enabled -Dtcl_version=tcl)
  else
    meson_args+=(-Dpltcl=disabled)
    log "Tcl runtime prefix not found; building without PL/Tcl"
  fi

  log "Configuring PostgreSQL ${POSTGRESQL_VERSION} with Meson for ${TARGET_TRIPLE}"
  (
    cd /work
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${SDK_PREFIX}/bin:${PATH}"
    export LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
    export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
    export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR=
    export LLVM_CONFIG="${LLVM_ROOT}/bin/llvm-config"

    meson setup "$POSTGRESQL_BUILD_DIR" "$POSTGRESQL_SOURCE_DIR" "${meson_args[@]}"
    meson compile -C "$POSTGRESQL_BUILD_DIR" -j "$JOBS"
    DESTDIR="$stage_dir" meson install -C "$POSTGRESQL_BUILD_DIR"
  )

  cp -a "${stage_dir}${SDK_PREFIX}/." "$SDK_PREFIX/"
}

build_postgresql_host_zic() {
  local host_build_dir="${BUILD_DIR}/postgresql-host-zic-build"
  local host_zic_path="${POSTGRESQL_BUILD_DIR}/src/timezone/zic-host"
  local host_configure_args=(
    --without-icu
    --without-ldap
    --without-pam
    --without-libxml
    --without-libxslt
    --without-gssapi
    --without-zlib
    --without-readline
    --without-lz4
    --without-zstd
    --without-perl
    --without-python
    --without-tcl
  )

  rm -rf "$host_build_dir"
  mkdir -p "$host_build_dir"

  (
    cd "$host_build_dir"
    env \
      PATH="${LLVM_ROOT}/bin:${PATH}" \
      CC="${LLVM_ROOT}/bin/clang" \
      CXX="${LLVM_ROOT}/bin/clang++" \
      CPP="${LLVM_ROOT}/bin/clang -E" \
      AR="${LLVM_ROOT}/bin/llvm-ar" \
      RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
      "${POSTGRESQL_SOURCE_DIR}/configure" \
      "${host_configure_args[@]}"
    make -j "$JOBS" -C src/timezone zic
  )

  install -m 755 "${host_build_dir}/src/timezone/zic" "$host_zic_path"
}

build_postgresql_configure() {
  local configure_args=()
  local configure_env=()
  local configure_cppflags=""
  local make_target="world-bin"

  detect_optional_language_support
  ensure_perl_prefix_alias
  ensure_python_prefix_alias
  rewrite_dependency_prefixes

  rm -rf "$POSTGRESQL_BUILD_DIR"
  mkdir -p "$POSTGRESQL_BUILD_DIR"

  configure_args=(
    --build="$CONFIGURE_BUILD_TRIPLE"
    --host="$CONFIGURE_HOST_TRIPLE"
    --prefix="$SDK_PREFIX"
  )

  case "$TARGET_KIND" in
    linux)
      configure_args+=(
        --with-system-tzdata="${SYSTEM_TZDATA_DIR}"
        --with-icu
        --with-ldap
        --with-openssl
        --with-libnuma
        --with-liburing
        --with-pam
        --with-libxml
        --with-libxslt
        --with-gssapi
        --with-zlib
        --with-readline
        --with-lz4
        --with-zstd
        --with-systemd
        --with-uuid=e2fs
      )
      ;;
    mingw)
      configure_args+=(
        --with-system-tzdata="${SYSTEM_TZDATA_DIR}"
        --with-icu
        --with-openssl
        --with-libxml
        --with-libxslt
        --with-zlib
        --with-readline
        --with-lz4
        --with-zstd
      )
      ;;
    *)
      die "unsupported TARGET_KIND: ${TARGET_KIND}"
      ;;
  esac

  if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" && -x "${LLVM_ROOT}/bin/llvm-config" ]]; then
    configure_args+=(--with-llvm)
  elif [[ "$TARGET_KIND" == "linux" ]]; then
    log "Target LLVM runtime not available for ${TARGET_TRIPLE}; building without JIT"
  fi

  if [[ "$ENABLE_PERL" -eq 1 ]]; then
    configure_args+=(--with-perl)
  else
    log "Perl runtime prefix not found; building without PL/Perl"
  fi

  if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
    configure_args+=(--with-python)
  else
    log "Python runtime prefix not found; building without PL/Python"
  fi

  if [[ "$ENABLE_TCL" -eq 1 ]]; then
      configure_args+=(--with-tcl)
      if [[ -f "${SDK_PREFIX}/lib/tclConfig.sh" ]]; then
        configure_args+=(--with-tclconfig="${SDK_PREFIX}/lib")
      fi
  else
    log "Tcl runtime prefix not found; building without PL/Tcl"
  fi

  log "Configuring PostgreSQL ${POSTGRESQL_VERSION} for ${TARGET_TRIPLE}"
  (
    cd "$POSTGRESQL_BUILD_DIR"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${SDK_PREFIX}/bin:${PATH}"
    export LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

    configure_cppflags="$COMMON_CPPFLAGS ${CPPFLAGS:-}"
    if [[ "$ENABLE_PERL" -eq 1 && -n "$PERL_CORE_DIR" ]]; then
      configure_cppflags="-I${PERL_CORE_DIR} ${configure_cppflags}"
    fi
    if [[ "$ENABLE_PYTHON" -eq 1 && -n "$PYTHON_INCLUDE_DIR" ]]; then
      configure_cppflags="-I${PYTHON_INCLUDE_DIR} ${configure_cppflags}"
    fi

    configure_env=(
      CC="$CC"
      CXX="$CXX"
      CPP="$CC -E"
      AR="$AR"
      RANLIB="$RANLIB"
      STRIP="$STRIP"
      NM="$NM"
      LLVM_CONFIG="${LLVM_ROOT}/bin/llvm-config"
      CLANG="${LLVM_ROOT}/bin/clang"
      WINDRES="${WINDRES:-}"
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
      PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
      PKG_CONFIG_SYSROOT_DIR=
      CPPFLAGS="$configure_cppflags"
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}"
      CXXFLAGS="$COMMON_CXXFLAGS ${CXXFLAGS:-}"
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}"
      LIBS="${COMMON_LIBS:-} ${LIBS:-}"
    )
    if [[ "$TARGET_KIND" == "linux" ]]; then
      configure_env+=(LDFLAGS_EX_BE="-Wl,--export-dynamic")
    fi
    if [[ "$ENABLE_PERL" -eq 1 ]]; then
      configure_env+=(PERL="$PERL_CONFIG_QUERY_BIN")
      if [[ -n "$PERL_ARCHLIB_DIR" && -n "$PERL_PRIVLIB_DIR" ]]; then
        configure_env+=(PERL5LIB="${PERL_ARCHLIB_DIR}:${PERL_PRIVLIB_DIR}")
      fi
    fi
    if [[ "$ENABLE_PYTHON" -eq 1 ]]; then
      configure_env+=(PYTHON="$PYTHON_CONFIG_QUERY_BIN")
    fi
    if [[ "$ENABLE_TCL" -eq 1 ]]; then
      configure_env+=(TCLSH="$TCL_CONFIG_QUERY_BIN")
    fi

    env "${configure_env[@]}" \
      "${POSTGRESQL_SOURCE_DIR}/configure" \
      "${configure_args[@]}"

    log "Building PostgreSQL ${POSTGRESQL_VERSION}"
    make -j "$JOBS" "$make_target"
    make install-"$make_target"

    if [[ "$TARGET_KIND" == "mingw" ]]; then
      log "Building zic.exe for host-side timezone packaging"
      make -C src/timezone zic
      log "Building native zic host tool for timezone packaging"
      build_postgresql_host_zic
    fi
  )
}

validate_postgresql() {
  local psql_bin="${SDK_PREFIX}/bin/psql${EXEEXT}"
  local postgres_bin="${SDK_PREFIX}/bin/postgres${EXEEXT}"
  local pg_config_bin="${SDK_PREFIX}/bin/pg_config${EXEEXT}"
  local runner_command=""

  [[ -x "$psql_bin" ]] || die "missing psql binary"
  [[ -x "$postgres_bin" ]] || die "missing postgres binary"
  [[ -x "$pg_config_bin" ]] || die "missing pg_config"

  case "$TARGET_KIND:$ARCH" in
    linux:x86_64)
      log "Running x86_64 PostgreSQL smoke test"
      LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
        "$psql_bin" --version
      LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
        "$pg_config_bin" --configure
      ;;
    linux:*)
      if [[ -n "$POSTGRESQL_TARGET_RUNNER" ]]; then
        log "Running ${TARGET_TRIPLE} PostgreSQL smoke test via target runner"
        runner_command="LD_LIBRARY_PATH='${SDK_PREFIX}/lib:${SYSROOT}/lib:${SYSROOT}/usr/lib:${SYSROOT}/lib64:${SYSROOT}/usr/lib64:${LD_LIBRARY_PATH:-}' ${POSTGRESQL_TARGET_RUNNER}"
        eval "${runner_command} \"${psql_bin}\" --version"
        eval "${runner_command} \"${pg_config_bin}\" --configure"
      else
        log "Target runner not configured; skipping runtime smoke test for ${TARGET_TRIPLE}"
      fi
      ;;
    mingw:*)
      log "Windows PostgreSQL binaries built; skipping runtime smoke test inside Linux container"
      ;;
  esac
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
POSTGRESQL_VERSION="${POSTGRESQL_VERSION:-18.4}"
POSTGRESQL_TARGET_RUNNER="${POSTGRESQL_TARGET_RUNNER:-}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/postgresql-${POSTGRESQL_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
POSTGRESQL_ARCHIVE="${POSTGRESQL_ARCHIVE:-}"
POSTGRESQL_ARCHIVE_NAME="postgresql-${POSTGRESQL_VERSION}.tar.bz2"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing dependency prefix: ${SDK_PREFIX}"
[[ -f "${SDK_PREFIX}/README.postgresql-dependencies" ]] || die "missing postgresql_dependencies marker in prefix"

require_command curl
require_command tar
require_command make
require_command meson
require_command patch
require_command pkg-config

case "$TARGET_KIND" in
  linux)
    MESON_SYSTEM="linux"
    MESON_CPU_FAMILY="$ARCH"
    MESON_CPU="$ARCH"
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    EXEEXT=""
    SYSTEM_TZDATA_DIR="${SYSTEM_TZDATA_DIR:-/usr/share/zoneinfo}"
    COPY_SYSTEM_TZDATA=0
    ;;
  mingw)
    MESON_SYSTEM="windows"
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-x86_64-w64-mingw32}"
    EXEEXT=".exe"
    SYSTEM_TZDATA_DIR="${SYSTEM_TZDATA_DIR:-${SDK_PREFIX}/share/timezone}"
    COPY_SYSTEM_TZDATA=0
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TRIPLE="$("${LLVM_ROOT}/bin/clang" -dumpmachine 2>/dev/null || echo x86_64-unknown-linux-gnu)"
CONFIGURE_BUILD_TRIPLE="${CONFIGURE_BUILD_TRIPLE:-$BUILD_TRIPLE}"
if [[ "$CONFIGURE_BUILD_TRIPLE" == "$CONFIGURE_HOST_TRIPLE" ]]; then
  CONFIGURE_BUILD_TRIPLE="${ARCH}-postgresqlbuild-linux-gnu"
fi

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
CXX="${CXX:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
WINDRES="${WINDRES:-${LLVM_ROOT}/bin/llvm-windres}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
if [[ "$TARGET_KIND" == "mingw" && ! -x "$WINDRES" ]]; then
  WINDRES="$(command -v llvm-windres 2>/dev/null || true)"
fi
if [[ "$TARGET_KIND" == "mingw" && -z "$WINDRES" ]]; then
  die "missing windres tool for mingw build"
fi

POSTGRESQL_SOURCE_DIR="${BUILD_DIR}/postgresql-source"
POSTGRESQL_BUILD_DIR="${BUILD_DIR}/postgresql-build"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"

mkdir -p "$POSTGRESQL_SOURCE_DIR" "$POSTGRESQL_BUILD_DIR" "$BUILD_TOOLS"

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "${LLVM_ROOT}/bin/clang"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-cc"
fi
if [[ ! -x "$CXX" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx" "${LLVM_ROOT}/bin/clang++"
  CXX="${BUILD_TOOLS}/${TARGET_TRIPLE}-cxx"
fi
if [[ "$TARGET_KIND" == "mingw" ]]; then
  write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres" "$WINDRES"
  WINDRES="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
fi

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include -I${SDK_PREFIX}/include/ncursesw -I${SDK_PREFIX}/include/libxml2"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_CXXFLAGS="${COMMON_CXXFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi
COMMON_LIBS=""
MESON_EXTRA_C_ARGS=", '-I${SDK_PREFIX}/include/ncursesw', '-I${SDK_PREFIX}/include/libxml2'"
MESON_EXTRA_LINK_ARGS=""
if [[ "$TARGET_KIND" == "linux" ]]; then
  MESON_EXTRA_LINK_ARGS+=" , '-Wl,-rpath-link,${SDK_PREFIX}/lib'"
  MESON_EXTRA_LINK_ARGS+=" , '-Wl,-rpath-link,${SYSROOT}/usr/lib'"
  MESON_EXTRA_LINK_ARGS+=" , '-Wl,-rpath-link,${SYSROOT}/usr/lib64'"
  MESON_EXTRA_LINK_ARGS+=" , '-Wl,-rpath-link,${SYSROOT}/lib'"
  MESON_EXTRA_LINK_ARGS+=" , '-Wl,-rpath-link,${SYSROOT}/lib64'"
fi
MESON_CROSS_FILE="${BUILD_DIR}/postgresql-meson-cross.ini"

export PATH="${BUILD_TOOLS}:${PATH}"
export PKG_CONFIG_PATH="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=

if [[ -z "$POSTGRESQL_ARCHIVE" ]]; then
  POSTGRESQL_ARCHIVE="${CACHE_DIR}/${POSTGRESQL_ARCHIVE_NAME}"
  download_archive "$(postgresql_archive_url)" "$POSTGRESQL_ARCHIVE_NAME"
fi
[[ -f "$POSTGRESQL_ARCHIVE" ]] || die "missing PostgreSQL archive: ${POSTGRESQL_ARCHIVE}"

extract_archive_source "$POSTGRESQL_SOURCE_DIR" "$POSTGRESQL_ARCHIVE" "configure"
if [[ "$TARGET_KIND" == "mingw" ]]; then
  apply_source_patch_once "${POSTGRESQL_SOURCE_DIR}" "${PATCH_DIR}/postgresql-mingw64-pgevent-exports.patch"
  apply_source_patch_once "${POSTGRESQL_SOURCE_DIR}" "${PATCH_DIR}/postgresql-mingw64-pltcl-importlib.patch"
fi
if [[ "$TARGET_KIND" == "linux" ]]; then
  build_postgresql_meson
else
  build_postgresql_configure
fi
copy_system_tzdata_into_prefix
remove_static_libraries
remove_postgresql_docs
rewrite_dependency_prefixes
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_postgresql

render_template "${TEMPLATE_DIR}/README.postgresql.in" "${SDK_PREFIX}/README.postgresql" \
  "POSTGRESQL_VERSION=${POSTGRESQL_VERSION}" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "ENABLE_PERL=$([[ "$ENABLE_PERL" -eq 1 ]] && printf yes || printf no)" \
  "ENABLE_PYTHON=$([[ "$ENABLE_PYTHON" -eq 1 ]] && printf yes || printf no)" \
  "ENABLE_TCL=$([[ "$ENABLE_TCL" -eq 1 ]] && printf yes || printf no)"

log "PostgreSQL ready: ${SDK_PREFIX}"
