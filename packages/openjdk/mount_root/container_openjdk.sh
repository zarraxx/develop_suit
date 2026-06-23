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

extract_tar_source() {
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

loongarch64_openjdk_srpm_archive_name() {
  local archive_name=""

  archive_name="$(basename "${LOONGARCH64_OPENJDK_SRPM_URL:-}")"
  case "$archive_name" in
    *.src.rpm|*.rpm)
      printf '%s\n' "$archive_name"
      ;;
    *)
      printf 'java-17-openjdk-17.0.17.0.10-1.lns23.src.rpm\n'
      ;;
  esac
}

extract_loongarch64_openjdk_srpm() {
  local srpm_archive="$1"
  local srpm_dir="${SOURCE_ROOT}/openjdk-srpm"
  local archive_marker="${srpm_dir}/.source-archive"
  local archive_name=""
  local source_archive=""
  local source_patch=""

  require_command rpm2cpio
  require_command cpio

  archive_name="$(basename "$srpm_archive")"
  if [[ ! -f "$archive_marker" ]] || ! grep -qx "$archive_name" "$archive_marker"; then
    rm -rf "$srpm_dir"
    mkdir -p "$srpm_dir"
    (
      cd "$srpm_dir"
      rpm2cpio "$srpm_archive" | cpio -idmu --quiet
    )
    printf '%s\n' "$archive_name" >"$archive_marker"
  fi

  source_archive="$(find "$srpm_dir" -maxdepth 1 -type f -name 'openjdk-*.tar.xz' | sort | head -n 1)"
  source_patch="$(find "$srpm_dir" -maxdepth 1 -type f -name 'jdk17-LoongArch64.patch' | sort | head -n 1)"
  [[ -f "$source_archive" ]] || die "missing OpenJDK source archive in SRPM: ${srpm_archive}"
  [[ -f "$source_patch" ]] || die "missing LoongArch64 OpenJDK patch in SRPM: ${srpm_archive}"

  OPENJDK_ARCHIVE="$source_archive"
  if [[ -z "${LOONGARCH64_OPENJDK_PATCH:-}" ]]; then
    LOONGARCH64_OPENJDK_PATCH="$source_patch"
  fi
}

ensure_host_zip() {
  local zip_source_dir="${SOURCE_ROOT}/zip"
  local zip_archive_name=""
  local zip_bin="${BUILD_TOOLS}/zip"
  local zip_cc=""
  local found_zip=""

  found_zip="$(command -v zip 2>/dev/null || true)"
  if [[ -n "$found_zip" && "$found_zip" != "$zip_bin" && -x "$found_zip" ]]; then
    rm -f "$zip_bin"
    ln -sf "$found_zip" "$zip_bin"
    return 0
  fi

  if [[ -x "$zip_bin" ]]; then
    return 0
  fi

  if [[ -z "${ZIP_ARCHIVE:-}" ]]; then
    zip_archive_name="$(basename "${ZIP_URL:-zip30.tar.gz}")"
    [[ "$zip_archive_name" == "download" ]] && zip_archive_name="zip30.tar.gz"
    ZIP_ARCHIVE="${CACHE_DIR}/${zip_archive_name}"
    download_archive "$ZIP_URL" "$zip_archive_name"
  fi

  log "Building host zip tool"
  extract_tar_source "$zip_source_dir" "$ZIP_ARCHIVE" "unix/Makefile"
  if [[ ! -e "${zip_source_dir}/.develop-suit-modern-libc.patch.applied" ]]; then
    (
      cd "$zip_source_dir"
      patch -p1 -i /work/mount_root/patch/infozip-zip30-modern-libc.patch
      touch .develop-suit-modern-libc.patch.applied
    )
  fi
  zip_cc="$(command -v gcc || command -v cc || true)"
  [[ -n "$zip_cc" ]] || zip_cc="${BUILD_CC_REAL:-cc}"
  (
    cd "$zip_source_dir"
    make -f unix/Makefile clean >/dev/null 2>&1 || true
    make -f unix/Makefile generic CC="$zip_cc" LOCAL_ZIP='-DNO_LCHMOD'
  )

  [[ -x "${zip_source_dir}/zip" ]] || die "failed to build host zip tool"
  rm -f "$zip_bin"
  cp -f "${zip_source_dir}/zip" "$zip_bin"
  chmod 755 "$zip_bin"
}

openjdk_source_archive_name() {
  case "${OPENJDK_SOURCE_URL:-}" in
    *github.com/loongson/jdk17u*) printf 'loongson-jdk17u-jdk-%s-ls-ga.tar.gz\n' "$OPENJDK_VERSION" ;;
    *github.com/loongson/jdk25u*) printf 'loongson-jdk25u-jdk-%s-ls-ga.tar.gz\n' "$OPENJDK_VERSION" ;;
    *.tar.gz|*.tgz) printf 'openjdk-%s-ga.tar.gz\n' "$OPENJDK_VERSION" ;;
    *) printf 'openjdk-%s-ga.tar.xz\n' "$OPENJDK_VERSION" ;;
  esac
}

boot_jdk_archive_name() {
  local archive_name=""

  archive_name="$(basename "${BOOT_JDK_URL:-}")"
  case "$archive_name" in
    *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz)
      printf '%s\n' "$archive_name"
      ;;
    *)
      printf 'boot-jdk-%s-linux-x64.tar.gz\n' "$OPENJDK_VERSION"
      ;;
  esac
}

openjdk_target_triplet() {
  case "${TARGET_KIND}:${ARCH}" in
    linux:x86_64) printf 'x86_64-linux-gnu\n' ;;
    linux:aarch64) printf 'aarch64-linux-gnu\n' ;;
    mingw:x86_64) printf 'x86_64-w64-windows-gnu\n' ;;
    linux:riscv64) printf 'riscv64-linux-gnu\n' ;;
    linux:loongarch64) printf 'loongarch64-linux-gnu\n' ;;
    *) die "unsupported OpenJDK target: ${TARGET_KIND}:${ARCH}" ;;
  esac
}

openjdk_patch_family() {
  case "${OPENJDK_SOURCE_URL:-}:${OPENJDK_VERSION:-}" in
    *github.com/loongson/jdk17u*|*:17.*) printf 'openjdk17' ;;
    *) printf 'openjdk25' ;;
  esac
}

apply_openjdk_patches() {
  local patch_family=""

  patch_family="$(openjdk_patch_family)"
  if [[ "$patch_family" == "openjdk17" \
      && "$ARCH" == "loongarch64" \
      && ! -e "${OPENJDK_SOURCE_DIR}/.develop-suit-openjdk17-loongarch64-config-sub.patch.applied" ]]; then
    (
      cd "$OPENJDK_SOURCE_DIR"
      patch -p1 -i /work/mount_root/patch/openjdk17-loongarch64-config-sub.patch
      touch .develop-suit-openjdk17-loongarch64-config-sub.patch.applied
    )
  fi
  if [[ "$patch_family" == "openjdk25" \
      && "$ARCH" == "riscv64" \
      && ! -e "${OPENJDK_SOURCE_DIR}/.develop-suit-openjdk25-riscv64-float-type-scope.patch.applied" ]]; then
    (
      cd "$OPENJDK_SOURCE_DIR"
      patch -p1 -i /work/mount_root/patch/openjdk25-riscv64-float-type-scope.patch
      touch .develop-suit-openjdk25-riscv64-float-type-scope.patch.applied
    )
  fi
  if [[ ! -e "${OPENJDK_SOURCE_DIR}/.develop-suit-${patch_family}-headless-runtime.patch.applied" ]]; then
    (
      cd "$OPENJDK_SOURCE_DIR"
      patch -p1 -i "/work/mount_root/patch/${patch_family}-headless-runtime-only.patch"
      touch ".develop-suit-${patch_family}-headless-runtime.patch.applied"
    )
  fi
  if [[ ! -e "${OPENJDK_SOURCE_DIR}/.develop-suit-${patch_family}-headless-runtime-ctsym.patch.applied" ]]; then
    (
      cd "$OPENJDK_SOURCE_DIR"
      patch -p1 -i "/work/mount_root/patch/${patch_family}-headless-runtime-ctsym.patch"
      touch ".develop-suit-${patch_family}-headless-runtime-ctsym.patch.applied"
    )
  fi
  if [[ ! -e "${OPENJDK_SOURCE_DIR}/.develop-suit-${patch_family}-headless-runtime-jmods.patch.applied" ]]; then
    (
      cd "$OPENJDK_SOURCE_DIR"
      patch -p1 -i "/work/mount_root/patch/${patch_family}-headless-runtime-jmods.patch"
      touch ".develop-suit-${patch_family}-headless-runtime-jmods.patch.applied"
    )
  fi
}

apply_openjdk_loongarch64_patch() {
  if [[ -z "${LOONGARCH64_OPENJDK_PATCH:-}" ]]; then
    return 0
  fi
  if [[ "$ARCH" != "loongarch64" ]]; then
    die "--loongarch64-openjdk-patch is only valid for loongarch64"
  fi
  if [[ ! -e "${OPENJDK_SOURCE_DIR}/.develop-suit-loongarch64-openjdk.patch.applied" ]]; then
    (
      cd "$OPENJDK_SOURCE_DIR"
      patch -p1 -i "$LOONGARCH64_OPENJDK_PATCH"
      touch .develop-suit-loongarch64-openjdk.patch.applied
    )
  fi
}

first_existing_dir() {
  local path=""
  for path in "$@"; do
    [[ -d "$path" ]] || continue
    printf '%s\n' "$path"
    return 0
  done
  return 0
}

filter_existing_openjdk_modules() {
  local modules="$1"
  local module=""
  local filtered=()
  local skipped=()

  for module in $modules; do
    if [[ -d "${OPENJDK_SOURCE_DIR}/src/${module}" ]]; then
      filtered+=("$module")
    else
      skipped+=("$module")
    fi
  done

  if [[ "${#skipped[@]}" -gt 0 ]]; then
    log "Skipping modules not present in OpenJDK source: ${skipped[*]}"
  fi

  printf '%s\n' "${filtered[*]}"
}

write_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"
  local extra_flags="${3:-}"
  local extra_link_flags="${4:-}"

  render_template "${TEMPLATE_DIR}/clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "TARGET_TRIPLE=${TARGET_TRIPLE}" \
    "SYSROOT=${SYSROOT}" \
    "EXTRA_FLAGS=${extra_flags}" \
    "EXTRA_LINK_FLAGS=${extra_link_flags}"
  chmod +x "$wrapper_path"
}

write_host_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"
  local extra_flags="${3:-}"
  local extra_link_flags="${4:-}"

  render_template "${TEMPLATE_DIR}/host-clang-wrapper.in" "$wrapper_path" \
    "REAL_COMPILER=${real_compiler}" \
    "EXTRA_FLAGS=${extra_flags}" \
    "EXTRA_LINK_FLAGS=${extra_link_flags}"
  chmod +x "$wrapper_path"
}

link_build_tool() {
  local link_name="$1"
  local tool_path="$2"

  [[ -x "$tool_path" ]] || die "missing tool for ${link_name}: ${tool_path}"
  ln -sf "$tool_path" "${BUILD_TOOLS}/${link_name}"
}

link_llvm_binutils() {
  link_build_tool ar "$AR"
  link_build_tool ranlib "$RANLIB"
  link_build_tool strip "$STRIP"
  link_build_tool nm "$NM"
  link_build_tool objcopy "$OBJCOPY"
  link_build_tool objdump "${OBJDUMP:-${LLVM_ROOT}/bin/llvm-objdump}"
  link_build_tool c++filt "${CXXFILT:-${LLVM_ROOT}/bin/llvm-cxxfilt}"
}

install_maven() {
  rm -rf "$MAVEN_DIR" "${SDK_PREFIX}/maven"
  mkdir -p "$MAVEN_DIR"
  unzip -q "$MAVEN_ARCHIVE" -d "$MAVEN_DIR"
  [[ -d "${MAVEN_DIR}/apache-maven-${MAVEN_VERSION}" ]] || die "invalid Maven archive"
  cp -a "${MAVEN_DIR}/apache-maven-${MAVEN_VERSION}" "${SDK_PREFIX}/maven"
}

install_prebuilt_jdk() {
  local archive_path="$1"
  local jdk_root=""

  rm -rf "$PREBUILT_DIR" "${SDK_PREFIX}/jdk"
  mkdir -p "$PREBUILT_DIR"
  case "$archive_path" in
    *.zip)
      unzip -q "$archive_path" -d "$PREBUILT_DIR"
      ;;
    *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|/work/input/*)
      if tar -tf "$archive_path" >/dev/null 2>&1; then
        tar -xf "$archive_path" -C "$PREBUILT_DIR"
      else
        unzip -q "$archive_path" -d "$PREBUILT_DIR"
      fi
      ;;
    *)
      die "unsupported prebuilt JDK archive: ${archive_path}"
      ;;
  esac
  jdk_root="$(find "$PREBUILT_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$jdk_root" ]] || die "invalid x86_64 prebuilt JDK archive"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    [[ -f "${jdk_root}/bin/java.exe" ]] || die "invalid Windows prebuilt JDK: missing bin/java.exe"
    find "${jdk_root}/bin" -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.cmd' \) -exec chmod 755 {} + 2>/dev/null || true
  else
    [[ -x "${jdk_root}/bin/java" ]] || die "invalid Linux prebuilt JDK: missing bin/java"
  fi
  cp -a "$jdk_root" "${SDK_PREFIX}/jdk"
}

extract_boot_jdk() {
  rm -rf "$BOOT_JDK_DIR"
  mkdir -p "$BOOT_JDK_DIR"
  tar -xf "$BOOT_JDK_ARCHIVE" -C "$BOOT_JDK_DIR" --strip-components=1
  [[ -x "${BOOT_JDK_DIR}/bin/java" ]] || die "invalid Boot JDK archive"
}

configure_and_build_source_jdk() {
  local openjdk_target=""
  local configure_args=()
  local make_args=()
  local pkg_config_paths=()
  local build_cxx_runtime_dir="${LLVM_ROOT}/lib/x86_64-unknown-linux-gnu"
  local build_cxx_link_flags=""
  local jvm_variants="${OPENJDK_JVM_VARIANTS:-server}"
  local default_headless_build_modules=""
  local default_headless_runtime_modules=""

  openjdk_target="$(openjdk_target_triplet)"
  if [[ -z "${OPENJDK_JVM_VARIANTS:-}" && "$ARCH" == "loongarch64" \
      && ! -d "${OPENJDK_SOURCE_DIR}/src/hotspot/cpu/loongarch" ]]; then
    jvm_variants="zero"
  fi

  COMMON_CFLAGS="-fPIC -Wno-unused-command-line-argument"
  COMMON_CXXFLAGS="-fPIC -Wno-unused-command-line-argument"
  COMMON_LDFLAGS="-Wl,--as-needed -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
  if [[ "$ARCH" == "riscv64" ]]; then
    COMMON_CFLAGS="-mno-relax ${COMMON_CFLAGS}"
    COMMON_CXXFLAGS="-mno-relax ${COMMON_CXXFLAGS}"
    COMMON_LDFLAGS="-Wl,--undefined-version -Wl,--no-relax ${COMMON_LDFLAGS}"
  fi
  if [[ "$ARCH" == "loongarch64" ]]; then
    COMMON_LDFLAGS="-Wl,--undefined-version ${COMMON_LDFLAGS}"
  fi
  default_headless_build_modules="java.base java.compiler java.datatransfer java.instrument java.logging java.management java.management.rmi java.naming java.net.http java.prefs java.rmi java.scripting java.security.jgss java.security.sasl java.sql java.sql.rowset java.transaction.xa java.xml java.xml.crypto jdk.attach jdk.charsets jdk.compiler jdk.crypto.cryptoki jdk.crypto.ec jdk.httpserver jdk.internal.ed jdk.internal.jvmstat jdk.internal.le jdk.internal.md jdk.internal.opt jdk.jartool jdk.javadoc jdk.jcmd jdk.jdeps jdk.jdi jdk.jdwp.agent jdk.jfr jdk.jlink jdk.localedata jdk.management jdk.management.agent jdk.naming.dns jdk.naming.rmi jdk.net jdk.nio.mapmode jdk.sctp jdk.security.auth jdk.security.jgss jdk.unsupported jdk.zipfs"
  default_headless_runtime_modules="java.base java.compiler java.datatransfer java.instrument java.logging java.management java.management.rmi java.naming java.net.http java.prefs java.rmi java.scripting java.security.jgss java.security.sasl java.sql java.sql.rowset java.transaction.xa java.xml java.xml.crypto jdk.attach jdk.charsets jdk.crypto.cryptoki jdk.crypto.ec jdk.httpserver jdk.internal.ed jdk.internal.jvmstat jdk.internal.le jdk.internal.md jdk.internal.opt jdk.jartool jdk.jcmd jdk.jdi jdk.jdwp.agent jdk.jfr jdk.localedata jdk.management jdk.management.agent jdk.naming.dns jdk.naming.rmi jdk.net jdk.nio.mapmode jdk.sctp jdk.security.auth jdk.security.jgss jdk.unsupported jdk.zipfs"
  HEADLESS_BUILD_MODULES="${HEADLESS_BUILD_MODULES:-$default_headless_build_modules}"
  HEADLESS_RUNTIME_MODULES="${HEADLESS_RUNTIME_MODULES:-$default_headless_runtime_modules}"
  HEADLESS_BUILD_MODULES="$(filter_existing_openjdk_modules "$HEADLESS_BUILD_MODULES")"
  HEADLESS_RUNTIME_MODULES="$(filter_existing_openjdk_modules "$HEADLESS_RUNTIME_MODULES")"
  if [[ -n "${FONTCONFIG_PREFIX:-}" ]]; then
    [[ -d "$FONTCONFIG_PREFIX" ]] || die "missing fontconfig dependency prefix: ${FONTCONFIG_PREFIX}"
    [[ -f "${FONTCONFIG_PREFIX}/include/freetype2/ft2build.h" ]] || die "missing FreeType headers: ${FONTCONFIG_PREFIX}"
    [[ -f "${FONTCONFIG_PREFIX}/include/fontconfig/fontconfig.h" ]] || die "missing fontconfig headers: ${FONTCONFIG_PREFIX}"
    [[ -f "${FONTCONFIG_PREFIX}/lib/pkgconfig/freetype2.pc" ]] || die "missing freetype2.pc: ${FONTCONFIG_PREFIX}"
    [[ -f "${FONTCONFIG_PREFIX}/lib/pkgconfig/fontconfig.pc" ]] || die "missing fontconfig.pc: ${FONTCONFIG_PREFIX}"

    COMMON_CFLAGS="-I${FONTCONFIG_PREFIX}/include -I${FONTCONFIG_PREFIX}/include/freetype2 ${COMMON_CFLAGS}"
    COMMON_CXXFLAGS="-I${FONTCONFIG_PREFIX}/include -I${FONTCONFIG_PREFIX}/include/freetype2 ${COMMON_CXXFLAGS}"
    COMMON_LDFLAGS="-L${FONTCONFIG_PREFIX}/lib -Wl,-rpath-link,${FONTCONFIG_PREFIX}/lib ${COMMON_LDFLAGS}"
    pkg_config_paths+=("${FONTCONFIG_PREFIX}/lib/pkgconfig" "${FONTCONFIG_PREFIX}/share/pkgconfig")
  fi

  write_clang_wrapper "${BUILD_TOOLS}/clang" "$TARGET_CC_REAL" "$COMMON_CFLAGS" "$COMMON_LDFLAGS"
  write_clang_wrapper "${BUILD_TOOLS}/clang++" "$TARGET_CXX_REAL" "$COMMON_CXXFLAGS" "$COMMON_LDFLAGS"
  write_host_clang_wrapper "${BUILD_TOOLS}/build-clang" "$BUILD_CC_REAL"
  if [[ -d "$build_cxx_runtime_dir" ]]; then
    build_cxx_link_flags="-L${build_cxx_runtime_dir} -Wl,-rpath,${build_cxx_runtime_dir} -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
  fi
  if [[ "$ARCH" == "loongarch64" ]]; then
    build_cxx_link_flags="${build_cxx_link_flags} -Wl,--undefined-version"
  fi
  write_host_clang_wrapper "${BUILD_TOOLS}/build-clang++" "$BUILD_CXX_REAL" "" "$build_cxx_link_flags"
  link_llvm_binutils
  configure_args=(
    --with-conf-name="${TARGET_TRIPLE}"
    --with-boot-jdk="$BOOT_JDK_DIR"
    --openjdk-target="$openjdk_target"
    --with-toolchain-type=clang
    --with-toolchain-path="$BUILD_TOOLS"
    --with-extra-path="${BUILD_TOOLS}:${LLVM_ROOT}/bin"
    --with-sysroot="$SYSROOT"
    --enable-headless-only
    --with-jvm-variants="$jvm_variants"
    --with-debug-level=release
    --with-native-debug-symbols=none
    --with-jobs="$JOBS"
    --disable-warnings-as-errors
    --with-version-opt=develop-suit
    --with-build-user=develop_suit
    --with-extra-cflags="$COMMON_CFLAGS"
    --with-extra-cxxflags="$COMMON_CXXFLAGS"
    --with-extra-ldflags="$COMMON_LDFLAGS"
    "BUILD_CC=${BUILD_TOOLS}/build-clang"
    "BUILD_CXX=${BUILD_TOOLS}/build-clang++"
  )
  if [[ -n "${FONTCONFIG_PREFIX:-}" ]]; then
    configure_args+=(
      --with-freetype=system
      --with-freetype-include="${FONTCONFIG_PREFIX}/include"
      --with-freetype-lib="${FONTCONFIG_PREFIX}/lib"
      --with-fontconfig="${FONTCONFIG_PREFIX}"
    )
  fi
  make_args=(CONF_NAME="$TARGET_TRIPLE" jdk-image JOBS="$JOBS" OPENJDK_HEADLESS_RUNTIME_ONLY=true)
  if [[ -n "${HEADLESS_RUNTIME_MODULES:-}" ]]; then
    make_args+=(
      ALL_MODULES="${HEADLESS_BUILD_MODULES:-$HEADLESS_RUNTIME_MODULES}"
      JAVA_MODULES="${HEADLESS_BUILD_MODULES:-$HEADLESS_RUNTIME_MODULES}"
      JMOD_MODULES="${HEADLESS_BUILD_MODULES:-$HEADLESS_RUNTIME_MODULES}"
      JDK_MODULES="$HEADLESS_RUNTIME_MODULES"
      JRE_MODULES="$HEADLESS_RUNTIME_MODULES"
    )
  fi
  log "Configuring OpenJDK ${OPENJDK_VERSION} for ${TARGET_TRIPLE} as ${openjdk_target}"
  (
    cd "$OPENJDK_SOURCE_DIR"
    env \
      PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
      PKG_CONFIG_PATH="$(IFS=:; echo "${pkg_config_paths[*]}")" \
      PKG_CONFIG_LIBDIR="$(IFS=:; echo "${pkg_config_paths[*]}")" \
      PKG_CONFIG_SYSROOT_DIR= \
      CC="${BUILD_TOOLS}/clang" \
      CXX="${BUILD_TOOLS}/clang++" \
      LD="${BUILD_TOOLS}/clang++" \
      AR="$AR" \
      NM="$NM" \
      OBJCOPY="$OBJCOPY" \
      RANLIB="$RANLIB" \
      STRIP="$STRIP" \
      BUILD_CC="${BUILD_TOOLS}/build-clang" \
      BUILD_CXX="${BUILD_TOOLS}/build-clang++" \
      OPENJDK_HEADLESS_RUNTIME_ONLY=true \
      bash configure "${configure_args[@]}"

    log "Building OpenJDK headless runtime image"
    make "${make_args[@]}"
  )

  [[ -x "${OPENJDK_SOURCE_DIR}/build/${TARGET_TRIPLE}/images/jdk/bin/java" ]] || die "missing built JDK image"
  rm -rf "${SDK_PREFIX}/jdk"
  cp -a "${OPENJDK_SOURCE_DIR}/build/${TARGET_TRIPLE}/images/jdk" "${SDK_PREFIX}/jdk"
}

install_launchers() {
  mkdir -p "${SDK_PREFIX}/bin"
  rm -f "${SDK_PREFIX}/bin/java" "${SDK_PREFIX}/bin/java.exe" \
    "${SDK_PREFIX}/bin/javac" "${SDK_PREFIX}/bin/javac.exe" \
    "${SDK_PREFIX}/bin/mvn" "${SDK_PREFIX}/bin/mvn.cmd"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    ln -s ../jdk/bin/java.exe "${SDK_PREFIX}/bin/java.exe"
    ln -s ../jdk/bin/javac.exe "${SDK_PREFIX}/bin/javac.exe"
    cat >"${SDK_PREFIX}/bin/mvn" <<'EOF'
#!/usr/bin/env sh
set -eu
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export JAVA_HOME="${JAVA_HOME:-${script_dir}/../jdk}"
exec "${script_dir}/../maven/bin/mvn" "$@"
EOF
    cat >"${SDK_PREFIX}/bin/mvn.cmd" <<'EOF'
@echo off
setlocal
if not defined JAVA_HOME set "JAVA_HOME=%~dp0..\jdk"
call "%~dp0..\maven\bin\mvn.cmd" %*
EOF
    chmod 755 "${SDK_PREFIX}/bin/mvn" "${SDK_PREFIX}/bin/mvn.cmd"
  else
    ln -s ../jdk/bin/java "${SDK_PREFIX}/bin/java"
    if [[ -x "${SDK_PREFIX}/jdk/bin/javac" ]]; then
      ln -s ../jdk/bin/javac "${SDK_PREFIX}/bin/javac"
    fi
    cat >"${SDK_PREFIX}/bin/mvn" <<'EOF'
#!/usr/bin/env sh
set -eu
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export JAVA_HOME="${JAVA_HOME:-${script_dir}/../jdk}"
exec "${script_dir}/../maven/bin/mvn" "$@"
EOF
    chmod 755 "${SDK_PREFIX}/bin/mvn"
  fi
}

validate_package() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    [[ -f "${SDK_PREFIX}/jdk/bin/java.exe" ]] || die "missing java.exe launcher"
    if [[ "${REQUIRE_JAVAC:-true}" == "true" ]]; then
      [[ -f "${SDK_PREFIX}/jdk/bin/javac.exe" ]] || die "missing javac.exe launcher"
    fi
  else
    [[ -x "${SDK_PREFIX}/jdk/bin/java" ]] || die "missing java launcher"
    if [[ "${REQUIRE_JAVAC:-true}" == "true" ]]; then
      [[ -x "${SDK_PREFIX}/jdk/bin/javac" ]] || die "missing javac launcher"
    fi
  fi
  [[ -x "${SDK_PREFIX}/maven/bin/mvn" ]] || die "missing Maven launcher"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
OPENJDK_VERSION="${OPENJDK_VERSION:-25.0.3}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.16}"
JOBS="${JOBS:-4}"
SDK_PREFIX="${SDK_PREFIX:-/opt/openjdk-${OPENJDK_VERSION}-${TARGET_TRIPLE}}"
CACHE_DIR="${CACHE_DIR:-/work/cache}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
FONTCONFIG_PREFIX="${FONTCONFIG_PREFIX:-}"

[[ -n "$ARCH" ]] || die "ARCH is required"
case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "OpenJDK package supports x86_64/aarch64/riscv64/loongarch64 Linux and x86_64 MinGW" ;;
esac
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$SDK_PREFIX" ]] || die "missing package prefix: ${SDK_PREFIX}"

require_command curl
require_command tar
require_command unzip
require_command make
require_command bash

SOURCE_ROOT="${BUILD_DIR}/src"
OPENJDK_SOURCE_DIR="${SOURCE_ROOT}/openjdk"
BOOT_JDK_DIR="${BUILD_DIR}/boot-jdk"
PREBUILT_DIR="${BUILD_DIR}/prebuilt-jdk"
MAVEN_DIR="${BUILD_DIR}/maven"
BUILD_TOOLS="${BUILD_DIR}/tools"
mkdir -p "$SOURCE_ROOT" "$BUILD_TOOLS" "${SDK_PREFIX}/bin"

if [[ -z "${MAVEN_ARCHIVE:-}" ]]; then
  MAVEN_ARCHIVE="${CACHE_DIR}/apache-maven-${MAVEN_VERSION}-bin.zip"
  download_archive "$MAVEN_URL" "$(basename "$MAVEN_ARCHIVE")"
fi

case "$ARCH" in
  x86_64)
    if [[ "$TARGET_KIND" == "mingw" ]]; then
      if [[ -z "${MINGW64_JDK_ARCHIVE:-}" ]]; then
        MINGW64_JDK_ARCHIVE="${CACHE_DIR}/zulu25.34.17-ca-jdk25.0.3-win_x64.zip"
        download_archive "$MINGW64_JDK_URL" "$(basename "$MINGW64_JDK_ARCHIVE")"
      fi
      install_prebuilt_jdk "$MINGW64_JDK_ARCHIVE"
    else
      if [[ -z "${X64_JDK_ARCHIVE:-}" ]]; then
        X64_JDK_ARCHIVE="${CACHE_DIR}/zulu25.34.17-ca-jdk25.0.3-linux_x64.tar.gz"
        download_archive "$X64_JDK_URL" "$(basename "$X64_JDK_ARCHIVE")"
      fi
      install_prebuilt_jdk "$X64_JDK_ARCHIVE"
    fi
    ;;
  aarch64)
    if [[ -z "${AARCH64_JDK_ARCHIVE:-}" ]]; then
      AARCH64_JDK_ARCHIVE="${CACHE_DIR}/zulu25.34.17-ca-jdk25.0.3-linux_aarch64.tar.gz"
      download_archive "$AARCH64_JDK_URL" "$(basename "$AARCH64_JDK_ARCHIVE")"
    fi
    install_prebuilt_jdk "$AARCH64_JDK_ARCHIVE"
    ;;
  riscv64|loongarch64)
    JDK_SOURCE="source"
    REQUIRE_JAVAC="${REQUIRE_JAVAC:-false}"
    [[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
    SYSROOT="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    [[ -d "$SYSROOT" ]] || die "missing sysroot: ${SYSROOT}"

    BUILD_CC_REAL="${BUILD_CC:-${LLVM_ROOT}/bin/clang}"
    BUILD_CXX_REAL="${BUILD_CXX:-${LLVM_ROOT}/bin/clang++}"
    TARGET_CC_REAL="${CC:-${LLVM_ROOT}/bin/clang}"
    TARGET_CXX_REAL="${CXX:-${LLVM_ROOT}/bin/clang++}"
    AR="${AR:-${LLVM_ROOT}/bin/llvm-ar}"
    RANLIB="${RANLIB:-${LLVM_ROOT}/bin/llvm-ranlib}"
    STRIP="${STRIP:-${LLVM_ROOT}/bin/llvm-strip}"
    NM="${NM:-${LLVM_ROOT}/bin/llvm-nm}"
    OBJCOPY="${OBJCOPY:-${LLVM_ROOT}/bin/llvm-objcopy}"

    [[ -x "$BUILD_CC_REAL" ]] || die "missing host C compiler: ${BUILD_CC_REAL}"
    [[ -x "$BUILD_CXX_REAL" ]] || die "missing host C++ compiler: ${BUILD_CXX_REAL}"
    [[ -x "$TARGET_CC_REAL" ]] || die "missing target C compiler: ${TARGET_CC_REAL}"
    [[ -x "$TARGET_CXX_REAL" ]] || die "missing target C++ compiler: ${TARGET_CXX_REAL}"

    if [[ -z "${OPENJDK_ARCHIVE:-}" ]]; then
      if [[ "$ARCH" == "loongarch64" \
          && ( -n "${LOONGARCH64_OPENJDK_SRPM_ARCHIVE:-}" \
            || -n "${LOONGARCH64_OPENJDK_SRPM_URL:-}" ) ]]; then
        if [[ -z "${LOONGARCH64_OPENJDK_SRPM_ARCHIVE:-}" ]]; then
          LOONGARCH64_OPENJDK_SRPM_ARCHIVE="${CACHE_DIR}/$(loongarch64_openjdk_srpm_archive_name)"
          download_archive "$LOONGARCH64_OPENJDK_SRPM_URL" "$(basename "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE")"
        fi
      else
        OPENJDK_ARCHIVE="${CACHE_DIR}/$(openjdk_source_archive_name)"
        download_archive "$OPENJDK_SOURCE_URL" "$(basename "$OPENJDK_ARCHIVE")"
      fi
    fi
    if [[ "$ARCH" == "loongarch64" && -n "${LOONGARCH64_OPENJDK_SRPM_ARCHIVE:-}" ]]; then
      extract_loongarch64_openjdk_srpm "$LOONGARCH64_OPENJDK_SRPM_ARCHIVE"
    fi
    if [[ -z "${BOOT_JDK_ARCHIVE:-}" ]]; then
      BOOT_JDK_ARCHIVE="${CACHE_DIR}/$(boot_jdk_archive_name)"
      download_archive "$BOOT_JDK_URL" "$(basename "$BOOT_JDK_ARCHIVE")"
    fi

    export PATH="${BOOT_JDK_DIR}/bin:${BUILD_TOOLS}:${LLVM_ROOT}/bin:${PATH}"
    export LANG=C
    export LC_ALL=C
    ensure_host_zip
    extract_tar_source "$OPENJDK_SOURCE_DIR" "$OPENJDK_ARCHIVE" "configure"
    apply_openjdk_loongarch64_patch
    apply_openjdk_patches
    extract_boot_jdk
    configure_and_build_source_jdk
    ;;
esac

install_maven
install_launchers
validate_package

render_template "${TEMPLATE_DIR}/README.openjdk.in" "${SDK_PREFIX}/README.openjdk" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "OPENJDK_TARGET_TRIPLE=$(openjdk_target_triplet)" \
  "OPENJDK_VERSION=${OPENJDK_VERSION}" \
  "MAVEN_VERSION=${MAVEN_VERSION}" \
  "LLVM_VERSION=${LLVM_VERSION}" \
  "JDK_SOURCE=${JDK_SOURCE:-prebuilt/source}"

log "OpenJDK package ready: ${SDK_PREFIX}"
