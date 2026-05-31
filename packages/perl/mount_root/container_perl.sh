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

write_exec_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  cat >"$wrapper_path" <<EOF
#!/bin/sh
exec "${real_tool}" "\$@"
EOF
  chmod +x "$wrapper_path"
}

write_cpp_wrapper() {
  local wrapper_path="$1"
  local real_cpp="${LLVM_ROOT}/bin/clang-cpp"

  if [[ -x "$real_cpp" ]]; then
    write_exec_wrapper "$wrapper_path" "$real_cpp"
  else
    cat >"$wrapper_path" <<EOF
#!/bin/sh
exec "${BUILD_CC}" -E "\$@"
EOF
    chmod +x "$wrapper_path"
  fi
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
    ! -path '*/CORE/libperl.a' \
    -delete
}

perl_archive_url() {
  printf '%s\n' "${PERL_ARCHIVE_URL:-https://cpan.metacpan.org/authors/id/S/SH/SHAY/${PERL_ARCHIVE_NAME}}"
}

apply_perl_patches() {
  require_command patch
  log "Applying Perl cross-runner patches"
  (
    cd "$PERL_SOURCE_DIR"
    chmod u+w Configure
    if grep -q 'PERL_TARGET_RUNNER' Configure; then
      log "Perl cross-runner patch was already applied"
    else
      patch -p1 -i /work/mount_root/patch/perl-configure-local-targetrun.patch
    fi
  )
}

build_target_perl() {
  local perl_target_arch="$TARGET_TRIPLE"
  local target_run_dir="${BUILD_DIR}/target-run"
  local perl_libs="-lm -lpthread -ldl -lcrypt"

  [[ "$TARGET_KIND" == "linux" ]] || die "MinGW Perl is not wired yet; use Linux targets for packages/perl"
  if [[ "$ARCH" != "x86_64" && -z "$PERL_TARGET_RUNNER" ]]; then
    die "Perl Configure needs a target runner for ${TARGET_TRIPLE}; pass --perl-target-runner"
  fi

  rm -rf "$target_run_dir"
  mkdir -p "$target_run_dir"

  if [[ -e "${SDK_PREFIX}/lib/libintl.so" || -e "${SDK_PREFIX}/lib/libintl.a" ]]; then
    perl_libs="${perl_libs} -lintl"
  fi

  log "Configuring Perl ${PERL_VERSION} for ${TARGET_TRIPLE}"
  (
    cd "$PERL_SOURCE_DIR"
    export PATH="${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    env \
      PERL_TARGET_RUNNER="$PERL_TARGET_RUNNER" \
      ./Configure -des \
        -Dusecrosscompile \
        -Dtargethost=localhost \
        -Dtargetrun=local \
        -Dtargetto=cp \
        -Dtargetfrom=cp \
        -Dtargetdir="$target_run_dir" \
        -Dtargetarch="$perl_target_arch" \
        -Darchname="$TARGET_TRIPLE" \
        -Dprefix="$SDK_PREFIX" \
        -Dvendorprefix="$SDK_PREFIX" \
        -Dsiteprefix="$SDK_PREFIX" \
        -Dinstallusrbinperl=n \
        -Duserelocatableinc \
        -Uuseshrplib \
        -Dusethreads \
        -Duse64bitall \
        -Dcc="$CC" \
        -Dar="$AR" \
        -Dranlib="$RANLIB" \
        -Dnm="$NM" \
        -Dld="$CC" \
        -Dsysroot="$SYSROOT" \
        -Dccflags="$COMMON_CPPFLAGS $COMMON_CFLAGS ${CFLAGS:-}" \
        -Dldflags="$COMMON_LDFLAGS ${LDFLAGS:-}" \
        -Dlocincpth="${SDK_PREFIX}/include" \
        -Dloclibpth="${SDK_PREFIX}/lib" \
        -Dlibpth="${SDK_PREFIX}/lib ${SYSROOT}/usr/lib ${SYSROOT}/usr/lib64 ${SYSROOT}/lib ${SYSROOT}/lib64" \
        -Dglibpth="${SDK_PREFIX}/lib ${SYSROOT}/usr/lib ${SYSROOT}/usr/lib64 ${SYSROOT}/lib ${SYSROOT}/lib64" \
        -Dlibs="$perl_libs"

    log "Building Perl ${PERL_VERSION}"
    make -j "$JOBS"
    make install
  )
}

validate_perl() {
  local perl_bin="${SDK_PREFIX}/bin/perl"

  [[ -x "$perl_bin" ]] || die "missing Perl executable: ${perl_bin}"

  if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" ]]; then
    log "Running x86_64 Perl smoke test"
    LD_LIBRARY_PATH="${SDK_PREFIX}/lib:${LD_LIBRARY_PATH:-}" "$perl_bin" -MConfig -e 'print "perl smoke ok $]\n"; print "$Config{archname}\n"'
  fi
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
PERL_VERSION="${PERL_VERSION:-5.42.2}"
PERL_TARGET_RUNNER="${PERL_TARGET_RUNNER:-}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/perl-${PERL_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
PERL_ARCHIVE="${PERL_ARCHIVE:-}"
PERL_ARCHIVE_NAME="perl-${PERL_VERSION}.tar.gz"

[[ -n "$ARCH" ]] || die "ARCH is required"
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing dependency prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command make

case "$TARGET_KIND" in
  linux)
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    TARGET_ROOT="$SYSROOT"
    ;;
  mingw)
    TARGET_ROOT="${TARGET_ROOT:-/opt/${TARGET_TRIPLE}}"
    SYSROOT="${SYSROOT:-${TARGET_ROOT}/sysroot}"
    ;;
  *)
    die "unsupported TARGET_KIND: ${TARGET_KIND}"
    ;;
esac
[[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

BUILD_CC="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
CC="${CC:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc}"
AR="${AR:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ar}"
RANLIB="${RANLIB:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-ranlib}"
STRIP="${STRIP:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-strip}"
NM="${NM:-${LLVM_ROOT}/bin/${TARGET_TRIPLE}-nm}"

[[ -x "$AR" ]] || AR="${LLVM_ROOT}/bin/llvm-ar"
[[ -x "$RANLIB" ]] || RANLIB="${LLVM_ROOT}/bin/llvm-ranlib"
[[ -x "$STRIP" ]] || STRIP="${LLVM_ROOT}/bin/llvm-strip"
[[ -x "$NM" ]] || NM="${LLVM_ROOT}/bin/llvm-nm"

SOURCE_ROOT="${BUILD_DIR}/src"
PERL_SOURCE_DIR="${SOURCE_ROOT}/perl"
BUILD_TOOLS="${BUILD_DIR}/tools"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"

mkdir -p "$SOURCE_ROOT" "$BUILD_TOOLS"

write_exec_wrapper "${BUILD_TOOLS}/cc" "$BUILD_CC"
write_exec_wrapper "${BUILD_TOOLS}/gcc" "$BUILD_CC"
write_cpp_wrapper "${BUILD_TOOLS}/cpp"
write_exec_wrapper "${BUILD_TOOLS}/ar" "${LLVM_ROOT}/bin/llvm-ar"
write_exec_wrapper "${BUILD_TOOLS}/ranlib" "${LLVM_ROOT}/bin/llvm-ranlib"
write_exec_wrapper "${BUILD_TOOLS}/nm" "${LLVM_ROOT}/bin/llvm-nm"

TARGET_AR_REAL="$AR"
TARGET_RANLIB_REAL="$RANLIB"
TARGET_STRIP_REAL="$STRIP"
TARGET_NM_REAL="$NM"
write_clang_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-gcc" "${LLVM_ROOT}/bin/clang"
write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-ar" "$TARGET_AR_REAL"
write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-ranlib" "$TARGET_RANLIB_REAL"
write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-strip" "$TARGET_STRIP_REAL"
write_exec_wrapper "${BUILD_TOOLS}/${TARGET_TRIPLE}-nm" "$TARGET_NM_REAL"
CC="${TARGET_TRIPLE}-gcc"
AR="${TARGET_TRIPLE}-ar"
RANLIB="${TARGET_TRIPLE}-ranlib"
STRIP="${TARGET_TRIPLE}-strip"
NM="${TARGET_TRIPLE}-nm"

COMMON_CPPFLAGS="-I${SDK_PREFIX}/include"
COMMON_CFLAGS="${COMMON_CFLAGS:-}"
COMMON_LDFLAGS="-L${SDK_PREFIX}/lib"
if [[ "$TARGET_KIND" == "linux" ]]; then
  COMMON_LDFLAGS="${COMMON_LDFLAGS} -Wl,-rpath,${SDK_PREFIX}/lib -Wl,-rpath-link,${SDK_PREFIX}/lib -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
fi

rewrite_dependency_prefixes

if [[ -z "$PERL_ARCHIVE" ]]; then
  download_archive "$(perl_archive_url)" "$PERL_ARCHIVE_NAME"
  PERL_ARCHIVE="${CACHE_DIR}/${PERL_ARCHIVE_NAME}"
fi

extract_archive_source "$PERL_SOURCE_DIR" "$PERL_ARCHIVE" "Configure"
apply_perl_patches

log "Installing Perl ${PERL_VERSION} into ${SDK_PREFIX}"
build_target_perl
rewrite_dependency_prefixes
remove_static_libraries
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"
validate_perl

render_template "${TEMPLATE_DIR}/README.perl.in" "${SDK_PREFIX}/README.perl" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "TARGET_KIND=${TARGET_KIND}" \
  "PERL_VERSION=${PERL_VERSION}"

log "Perl package ready: ${SDK_PREFIX}"
