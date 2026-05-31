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

write_windres_wrapper() {
  local wrapper_path="$1"

  cat >"$wrapper_path" <<EOF
#!/bin/sh
exec "${RC}" --target="${WINDRES_TARGET}" -I "${MINGW_INCLUDE_DIR}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

rewrite_dependency_prefixes() {
  local installed_file=""
  local old_prefix=""

  while IFS= read -r -d '' installed_file; do
    case "$installed_file" in
      *.pc|*.cmake|*.la|*.m4|*.cfg|*.conf|*.txt|*.md|*.sh|*.h|*.hh|*.hpp|*/bin/*-config|*/bin/*_config|*/README.*)
        ;;
      *)
        continue
        ;;
    esac
    for old_prefix in \
        "/opt/python_dependencies-${TARGET_TRIPLE}" \
        "/opt/pyhton_dependencies-3-${TARGET_TRIPLE}" \
        "/opt/llvm_dependencies-${TARGET_TRIPLE}"; do
      if grep -IqF "$old_prefix" "$installed_file"; then
        sed -i "s#${old_prefix}#${SDK_PREFIX}#g" "$installed_file"
      fi
    done
  done < <(
    find "$SDK_PREFIX" -type f -print0 2>/dev/null
  )
}

remove_static_libraries() {
  find "${SDK_PREFIX}/lib" -type f -name '*.la' -delete
  find "${SDK_PREFIX}/lib" -type f -name '*.a' \
    ! -name '*.dll.a' \
    ! -name 'libtclstub*.a' \
    -delete
}

copy_mingw_dependency_dlls_to_bin() {
  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  mkdir -p "${SDK_PREFIX}/bin"

  find "${SDK_PREFIX}/lib" \
    \( -type f -name '*.dll' -o -type l -name '*.dll' \) \
    -exec cp -f {} "${SDK_PREFIX}/bin/" \; 2>/dev/null || true
}

tcl_archive_url() {
  printf '%s\n' "${TCL_ARCHIVE_URL:-https://prdownloads.sourceforge.net/tcl/${TCL_ARCHIVE_NAME}}"
}

build_host_tcl() {
  if [[ -x "$HOST_TCLSH" ]]; then
    log "Reusing host Tcl helper: ${HOST_TCLSH}"
    return 0
  fi

  rm -rf "$HOST_BUILD_DIR" "$HOST_PREFIX"
  mkdir -p "$HOST_BUILD_DIR" "$HOST_PREFIX"

  log "Building host Tcl helper"
  (
    cd "$HOST_BUILD_DIR"
    env \
      CC="$BUILD_CC" \
      AR="${LLVM_ROOT}/bin/llvm-ar" \
      RANLIB="${LLVM_ROOT}/bin/llvm-ranlib" \
      STRIP="${LLVM_ROOT}/bin/llvm-strip" \
      CPPFLAGS= \
      CFLAGS= \
      LDFLAGS= \
      "${TCL_SOURCE_DIR}/unix/configure" \
        --prefix="$HOST_PREFIX" \
        --enable-shared \
        --enable-threads \
        --with-tzdata=no
    make -j "$JOBS" binaries libraries
  )

  [[ -x "$HOST_TCLSH" ]] || die "missing host Tcl helper: ${HOST_TCLSH}"
}

build_target_tcl() {
  local configure_dir="${TCL_SOURCE_DIR}/unix"
  local configure_args=()
  local make_args=()

  rm -rf "$TARGET_BUILD_DIR"
  mkdir -p "$TARGET_BUILD_DIR"

  configure_args=(
    --build="$CONFIGURE_BUILD_TRIPLE"
    --host="$CONFIGURE_HOST_TRIPLE"
    --prefix="$SDK_PREFIX"
    --enable-shared
    --enable-threads
    --with-tzdata=no
  )
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    configure_dir="${TCL_SOURCE_DIR}/win"
    configure_args+=(--enable-64bit)
    make_args+=(TCL_EXE="$HOST_TCLSH")
  fi

  log "Configuring Tcl ${TCL_VERSION} for ${TARGET_TRIPLE}"
  (
    cd "$TARGET_BUILD_DIR"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    export LD_LIBRARY_PATH="${HOST_BUILD_DIR}:${LD_LIBRARY_PATH:-}"
    env \
      ac_cv_path_tclsh="$HOST_TCLSH" \
      CC="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      NM="$NM" \
      RC="${WINDRES:-}" \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_LIBDIR="${SDK_PREFIX}/lib/pkgconfig:${SDK_PREFIX}/share/pkgconfig" \
      PKG_CONFIG_PATH= \
      PKG_CONFIG_SYSROOT_DIR= \
      CPPFLAGS="$COMMON_CPPFLAGS ${CPPFLAGS:-}" \
      CFLAGS="$COMMON_CFLAGS ${CFLAGS:-}" \
      LDFLAGS="$COMMON_LDFLAGS ${LDFLAGS:-}" \
      LIBS="$COMMON_LIBS ${LIBS:-}" \
      "${configure_dir}/configure" \
        "${configure_args[@]}"

    log "Building Tcl ${TCL_VERSION}"
    make -j "$JOBS" binaries libraries "${make_args[@]}"
    make install-binaries install-libraries install-headers "${make_args[@]}"
  )
}

fix_linux_tclsh_launcher() {
  local tclsh_path="${SDK_PREFIX}/bin/tclsh${TCL_SHORT_VERSION}"
  local tclsh_real="${tclsh_path}.bin"
  local tclsh_link="${SDK_PREFIX}/bin/tclsh"

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  [[ -x "$tclsh_path" ]] || die "missing Tcl shell: ${tclsh_path}"

  rm -f "$tclsh_real"
  mv "$tclsh_path" "$tclsh_real"
  cat >"$tclsh_path" <<EOF
#!/bin/sh
script_dir=\$(CDPATH= cd "\$(dirname "\$0")" && pwd)
TCL_LIBRARY="\${TCL_LIBRARY:-\${script_dir}/../lib/tcl${TCL_SHORT_VERSION}}"
export TCL_LIBRARY
exec "\${script_dir}/tclsh${TCL_SHORT_VERSION}.bin" "\$@"
EOF
  chmod 755 "$tclsh_path"

  rm -f "$tclsh_link"
  ln -s "tclsh${TCL_SHORT_VERSION}" "$tclsh_link"
}

fix_tcl_config_prefixes() {
  local config_file=""

  while IFS= read -r -d '' config_file; do
    if grep -IqF "$TARGET_BUILD_DIR" "$config_file"; then
      sed -i "s#${TARGET_BUILD_DIR}#${SDK_PREFIX}#g" "$config_file"
    fi
    if grep -IqF "$TCL_SOURCE_DIR" "$config_file"; then
      sed -i "s#${TCL_SOURCE_DIR}#${SDK_PREFIX}/src-placeholder#g" "$config_file"
    fi
  done < <(
    find "${SDK_PREFIX}/lib" -type f \( -name 'tclConfig.sh' -o -name 'tclooConfig.sh' -o -name '*.pc' \) -print0 2>/dev/null
  )
}

validate_tcl() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    [[ -f "${SDK_PREFIX}/bin/tclsh86.exe" ]] || die "missing MinGW Tcl shell"
    [[ -f "${SDK_PREFIX}/bin/tcl86.dll" || -f "${SDK_PREFIX}/lib/tcl86.dll" ]] || die "missing MinGW Tcl DLL"
    return 0
  fi

  [[ -x "${SDK_PREFIX}/bin/tclsh${TCL_SHORT_VERSION}" ]] || die "missing Tcl shell"
  [[ -f "${SDK_PREFIX}/lib/libtcl${TCL_SHORT_VERSION}.so" ]] || die "missing Tcl shared library"

  if [[ "$ARCH" == "x86_64" ]]; then
    log "Running x86_64 Tcl smoke test"
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
      "${SDK_PREFIX}/bin/tclsh${TCL_SHORT_VERSION}" <<'TCL'
puts "tcl smoke ok [info patchlevel]"
package require Tcl
TCL
  fi
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
TCL_VERSION="${TCL_VERSION:-8.6.18}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/tcl-${TCL_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
TCL_ARCHIVE="${TCL_ARCHIVE:-}"
TCL_ARCHIVE_NAME="tcl${TCL_VERSION}-src.tar.gz"
TCL_SHORT_VERSION="${TCL_VERSION%.*}"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing dependency prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make
require_command pkg-config

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-$TARGET_TRIPLE}"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    CONFIGURE_HOST_TRIPLE="${CONFIGURE_HOST_TRIPLE:-x86_64-w64-mingw32}"
    WINDRES_TARGET="${WINDRES_TARGET:-pe-x86-64}"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_TRIPLE="$("${LLVM_ROOT}/bin/clang" -dumpmachine 2>/dev/null || echo x86_64-unknown-linux-gnu)"
CONFIGURE_BUILD_TRIPLE="${CONFIGURE_BUILD_TRIPLE:-$BUILD_TRIPLE}"
if [[ "$CONFIGURE_BUILD_TRIPLE" == "$CONFIGURE_HOST_TRIPLE" ]]; then
  CONFIGURE_BUILD_TRIPLE="${ARCH}-tclbuild-linux-gnu"
fi

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"
RC="${RC:-${LLVM_ROOT}/bin/llvm-windres}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"
[[ -x "$RC" ]] || RC="${LLVM_ROOT}/bin/llvm-rc"

SOURCE_ROOT="${BUILD_DIR}/src"
TCL_SOURCE_DIR="${SOURCE_ROOT}/tcl"
HOST_BUILD_DIR="${BUILD_DIR}/build-host-tcl"
HOST_PREFIX="${BUILD_DIR}/host-tcl"
HOST_TCLSH="${HOST_BUILD_DIR}/tclsh"
TARGET_BUILD_DIR="${BUILD_DIR}/build-target-tcl"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"

mkdir -p "$SOURCE_ROOT" "$BUILD_TOOLS"

if [[ ! -x "$CC" ]]; then
  write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-cc" "${LLVM_ROOT}/bin/clang"
  CC="${BUILD_TOOLS}/${TARGET_TRIPLE}-cc"
fi
if [[ "$TARGET_KIND" == "mingw" ]]; then
  MINGW_INCLUDE_DIR="${MINGW_INCLUDE_DIR:-${SYSROOT}/usr/${TARGET_TRIPLE}/include}"
  [[ -d "$MINGW_INCLUDE_DIR" ]] || die "missing MinGW include directory: ${MINGW_INCLUDE_DIR}"
  write_windres_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
  WINDRES="${BUILD_TOOLS}/${TARGET_TRIPLE}-windres"
else
  WINDRES=
fi

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
COMMON_LIBS="${COMMON_LIBS:-}"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi

rewrite_dependency_prefixes

if [[ -z "$TCL_ARCHIVE" ]]; then
  download_archive "$(tcl_archive_url)" "$TCL_ARCHIVE_NAME"
  TCL_ARCHIVE="${CACHE_DIR}/${TCL_ARCHIVE_NAME}"
fi

extract_archive_source "$TCL_SOURCE_DIR" "$TCL_ARCHIVE" "unix/configure"

log "Installing Tcl ${TCL_VERSION} into ${SDK_PREFIX}"
build_host_tcl
build_target_tcl
fix_linux_tclsh_launcher
fix_tcl_config_prefixes
rewrite_dependency_prefixes
copy_mingw_dependency_dlls_to_bin
remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_tcl

render_template "${TEMPLATE_DIR}/README.tcl.in" "${SDK_PREFIX}/README.tcl" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "TCL_VERSION=${TCL_VERSION}"

log "Tcl package ready: ${SDK_PREFIX}"
