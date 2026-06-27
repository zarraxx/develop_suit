#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

log() {
  echo "==> $*" >&2
}

gn_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

target_cpu_for_gn() {
  case "$ARCH" in
    x86_64) printf '%s\n' "x64" ;;
    aarch64) printf '%s\n' "arm64" ;;
    riscv64) printf '%s\n' "riscv64" ;;
    loongarch64) printf '%s\n' "loong64" ;;
    *) return 1 ;;
  esac
}

target_os_for_gn() {
  case "$TARGET_KIND" in
    linux) printf '%s\n' "linux" ;;
    mingw) printf '%s\n' "win" ;;
    *) return 1 ;;
  esac
}

write_gclient_config() {
  mkdir -p "$DEP_SOURCE_DIR"
  rm -f "${DEP_SOURCE_DIR}/.gclient_entries" "${DEP_SOURCE_DIR}/.gclient_previous_custom_vars"
  cat >"${DEP_SOURCE_DIR}/.gclient" <<EOF
solutions = [
  {
    "name": "v8",
    "url": "https://chromium.googlesource.com/v8/v8.git@${V8_VERSION}",
    "deps_file": "DEPS",
    "custom_deps": {
      "v8/test/test262/data": None,
      "v8/third_party/icu": None,
      "v8/third_party/perfetto": None,
      "v8/third_party/protobuf": None,
    },
    "custom_vars": {
      "checkout_benchmarks": False,
      "checkout_v8_perf": False,
      "checkout_clang_tidy": False,
      "checkout_clangd": False,
      "checkout_v8_builtins_pgo_profiles": False,
    },
  },
]
EOF
}

ensure_v8_checkout() {
  write_gclient_config

  if [[ ! -d "${V8_SOURCE_DIR}/.git" ]]; then
    rm -rf "$V8_SOURCE_DIR"
    log "Fetching official V8 checkout with gclient"
    (cd "$DEP_SOURCE_DIR" && gclient sync --nohooks --no-history --with_branch_heads --with_tags -D --jobs "$GCLIENT_JOBS")
  fi

  [[ -d "${V8_SOURCE_DIR}/.git" ]] || die "missing V8 checkout: ${V8_SOURCE_DIR}"

  log "Checking out V8 ${V8_VERSION}"
  if ! git -C "$V8_SOURCE_DIR" rev-parse -q --verify "refs/tags/${V8_VERSION}" >/dev/null; then
    git -C "$V8_SOURCE_DIR" fetch --depth=1 origin "refs/tags/${V8_VERSION}:refs/tags/${V8_VERSION}"
  fi
  git -C "$V8_SOURCE_DIR" checkout --detach "${V8_VERSION}"
  revert_v8_patches_if_applied

  log "Syncing V8 dependencies"
  (cd "$DEP_SOURCE_DIR" && gclient sync --nohooks --no-history --with_branch_heads --with_tags -D --jobs "$GCLIENT_JOBS")
}

ensure_lastchange_timestamp() {
  local lastchange_file="${V8_SOURCE_DIR}/build/util/LASTCHANGE"
  local timestamp_file="${V8_SOURCE_DIR}/build/util/LASTCHANGE.committime"
  local revision=""
  local timestamp=""
  local year=""
  local tmp_file=""

  [[ -d "${V8_SOURCE_DIR}/.git" ]] || die "missing V8 git checkout: ${V8_SOURCE_DIR}"
  mkdir -p "$(dirname "$lastchange_file")"

  revision="$(git -C "$V8_SOURCE_DIR" log -1 --format=%H)"
  timestamp="$(git -C "$V8_SOURCE_DIR" log -1 --format=%ct)"
  year="$(date -u -d "@${timestamp}" +%Y)"

  tmp_file="${lastchange_file}.tmp"
  {
    printf 'LASTCHANGE=%s\n' "$revision"
    printf 'LASTCHANGE_YEAR=%s\n' "$year"
  } >"$tmp_file"
  if [[ ! -f "$lastchange_file" ]] || ! cmp -s "$tmp_file" "$lastchange_file"; then
    mv -f "$tmp_file" "$lastchange_file"
  else
    rm -f "$tmp_file"
  fi

  tmp_file="${timestamp_file}.tmp"
  printf '%s\n' "$timestamp" >"$tmp_file"
  if [[ ! -f "$timestamp_file" ]] || ! cmp -s "$tmp_file" "$timestamp_file"; then
    mv -f "$tmp_file" "$timestamp_file"
  else
    rm -f "$tmp_file"
  fi
}

revert_v8_patches_if_applied() {
  local marker="${V8_SOURCE_DIR}/.develop-suit-v8-gn-patches"
  local patch_file=""

  [[ -f "$marker" ]] || return 0

  log "Reverting previously applied V8 GN package patches before gclient sync"
  while IFS= read -r patch_file; do
    [[ -n "$patch_file" ]] || continue
    (cd "$V8_SOURCE_DIR" && patch -p1 -R -i "${PATCH_DIR}/${patch_file}")
  done <"$marker"
  rm -f "$marker"
}

apply_v8_patches() {
  local marker="${V8_SOURCE_DIR}/.develop-suit-v8-gn-patches"
  local patch_file=""
  local patch_set=""
  local patch_files=(
    v8-11.6.189.4-external-linux-sysroot-key.patch
    v8-11.6.189.4-use-external-zlib.patch
    v8-11.6.189.4-use-system-zlib-header.patch
  )
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    patch_files+=(
      v8-11.6.189.4-mingw-gn-toolchain.patch
      v8-11.6.189.4-mingw-export-template.patch
      v8-11.6.189.4-mingw-platform-guards.patch
      v8-11.6.189.4-mingw-solink-pe-dll-toc.patch
    )
  fi

  printf -v patch_set '%s\n' "${patch_files[@]}"
  if [[ -f "$marker" ]] && cmp -s "$marker" <(printf '%s' "$patch_set"); then
    return 0
  fi
  if [[ -f "$marker" ]]; then
    die "V8 source tree has a different patch set; rerun with --clean for ${TARGET_TRIPLE}"
  fi

  log "Applying V8 GN package patches"
  for patch_file in "${patch_files[@]}"; do
    (cd "$V8_SOURCE_DIR" && patch -p1 -i "${PATCH_DIR}/${patch_file}")
  done
  printf '%s' "$patch_set" >"$marker"
}

ensure_host_gn() {
  local gn_revision=""
  local gn_source_dir="/work/cache/gn-src"
  local gn_build_dir="/work/cache/gn-build"
  local gn_prefix="/work/cache/gn-host"
  local gn_bin="${gn_prefix}/bin/gn"
  local gn_marker="${gn_prefix}/.revision"
  local gn_tool_dir="/work/cache/gn-tools/bin"
  local host_triple="x86_64-unknown-linux-gnu"
  local llvm_host_lib="${LLVM_ROOT}/lib/${host_triple}"
  local llvm_host_include="${LLVM_ROOT}/include/${host_triple}/c++/v1"
  local gn_cxxflags=()
  local gn_ldflags=()

  gn_revision="$(sed -n "s/.*'gn_version': 'git_revision:\([^']*\)'.*/\1/p" "${V8_SOURCE_DIR}/DEPS" | sed -n '1p')"
  [[ -n "$gn_revision" ]] || die "unable to resolve GN revision from ${V8_SOURCE_DIR}/DEPS"

  if [[ -x "$gn_bin" ]] && [[ -f "$gn_marker" ]] && grep -qx "$gn_revision" "$gn_marker"; then
    export PATH="${gn_prefix}/bin:${PATH}"
    return 0
  fi

  log "Building host GN ${gn_revision}"
  [[ -d "$llvm_host_lib" ]] || die "missing host LLVM lib directory: ${llvm_host_lib}"
  [[ -d "$llvm_host_include" ]] || die "missing host LLVM libc++ headers: ${llvm_host_include}"
  gn_cxxflags=(
    "-stdlib=libc++"
    "-I${llvm_host_include}"
  )
  gn_ldflags=(
    "-stdlib=libc++"
    "-L${llvm_host_lib}"
    "-Wl,-rpath,${llvm_host_lib}"
  )
  mkdir -p "$(dirname "$gn_source_dir")" "$gn_prefix/bin" "$gn_tool_dir"
  ln -sf "${LLVM_ROOT}/bin/llvm-ar" "${gn_tool_dir}/ar"
  if [[ ! -d "${gn_source_dir}/.git" ]]; then
    rm -rf "$gn_source_dir"
    git clone --no-checkout https://gn.googlesource.com/gn "$gn_source_dir"
  fi

  git -C "$gn_source_dir" fetch --depth=1 origin "$gn_revision"
  git -C "$gn_source_dir" checkout --detach "$gn_revision"
  rm -rf "$gn_build_dir"

  CC="${LLVM_ROOT}/bin/clang" \
    CXX="${LLVM_ROOT}/bin/clang++" \
    CXXFLAGS="${gn_cxxflags[*]}" \
    LDFLAGS="${gn_ldflags[*]}" \
    LD_LIBRARY_PATH="${llvm_host_lib}:${LD_LIBRARY_PATH:-}" \
    python3 "${gn_source_dir}/build/gen.py" \
      --out-path "$gn_build_dir" \
      --no-last-commit-position \
      --no-static-libstdc++ \
      --link-lib=-lc++abi \
      --link-lib=-lunwind
  cat >"${gn_build_dir}/last_commit_position.h" <<EOF
#ifndef OUT_LAST_COMMIT_POSITION_H_
#define OUT_LAST_COMMIT_POSITION_H_

#define LAST_COMMIT_POSITION_NUM 0
#define LAST_COMMIT_POSITION "${gn_revision}"

#endif  // OUT_LAST_COMMIT_POSITION_H_
EOF
  CXXFLAGS="${gn_cxxflags[*]}" \
    LDFLAGS="${gn_ldflags[*]}" \
    LD_LIBRARY_PATH="${llvm_host_lib}:${LD_LIBRARY_PATH:-}" \
    PATH="${gn_tool_dir}:${PATH}" \
    ninja -C "$gn_build_dir" gn
  cp -f "${gn_build_dir}/gn" "$gn_bin"
  chmod 755 "$gn_bin"
  printf '%s\n' "$gn_revision" >"$gn_marker"

  export PATH="${gn_prefix}/bin:${PATH}"
}

require_host_gn_from_source() {
  local expected_gn="/work/cache/gn-host/bin/gn"
  local actual_gn=""

  actual_gn="$(command -v gn || true)"
  [[ "$actual_gn" == "$expected_gn" ]] \
    || die "expected source-built host gn at ${expected_gn}, got: ${actual_gn:-not found}"
  log "Using source-built host GN: ${actual_gn}"
}

write_mingw_clang_wrapper() {
  local wrapper_path="$1"
  local real_compiler="$2"

  cat >"$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_compiler="__REAL_COMPILER__"
mingw_lib_dir="/opt/__TARGET_TRIPLE__/sysroot/usr/x86_64-w64-windows-gnu/lib"
args=()
if [[ -d "$mingw_lib_dir" ]]; then
  args+=("-L${mingw_lib_dir}")
fi

rewrite_mingw_arg() {
  local value="$1"
  case "$value" in
    -l*.lib) printf '%s\n' "${value%.lib}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

for arg in "$@"; do
  case "$arg" in
    @*)
      rsp_path="${arg#@}"
      if [[ -f "$rsp_path" ]]; then
        rsp_tmp="$(mktemp "${TMPDIR:-/tmp}/mingw-rsp.XXXXXX")"
        sed -E 's/-l([^[:space:]]+)\.lib/-l\1/g' "$rsp_path" >"$rsp_tmp"
        args+=("@${rsp_tmp}")
      else
        args+=("$arg")
      fi
      ;;
    --color-diagnostics) args+=("-fcolor-diagnostics") ;;
    /clang:*) args+=("${arg#/clang:}") ;;
    /D*) args+=("-D${arg#/D}") ;;
    /I*) args+=("-I${arg#/I}") ;;
    /std:c11) args+=("-std=c11") ;;
    /std:c++*) args+=("-std=c++${arg#/std:c++}") ;;
    /O1) args+=("-O1") ;;
    /O2) args+=("-O2") ;;
    /Oy-) args+=("-fno-omit-frame-pointer") ;;
    -l*.lib) args+=("$(rewrite_mingw_arg "$arg")") ;;
    -Wl,-soname=*) ;;
    /TC|/TP|/MD|/MDd|/MT|/MTd|/Brepro|/Ob*|/Gw|/Oi|/GR*|/EH*|/Zc:*|/guard:*|/W*|/wd*|/CETCOMPAT|/call-graph-profile-sort:*|/lldignoreenv|/pdbpagesize:*|/PDBSourcePath:*|/DEBUG|/pdbaltpath:*|/TIMESTAMP:*|/OPT:*|/INCREMENTAL*|/FIXED:*|/PROFILE|/STACK:*|/manifest:*|/manifestuac:*|/manifestinput:*)
      ;;
    *) args+=("$arg") ;;
  esac
done

exec "$real_compiler" "${args[@]}"
EOF
  sed -i "s|__REAL_COMPILER__|${real_compiler}|g" "$wrapper_path"
  sed -i "s|__TARGET_TRIPLE__|${TARGET_TRIPLE}|g" "$wrapper_path"
  chmod 755 "$wrapper_path"
}

write_exec_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${real_tool}" "\$@"
EOF
  chmod 755 "$wrapper_path"
}

write_mingw_ar_wrapper() {
  local wrapper_path="$1"
  local real_tool="$2"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

args=()
for arg in "\$@"; do
  case "\$arg" in
    /WX) ;;
    /llvmlibthin) args+=("--thin") ;;
    *) args+=("\$arg") ;;
  esac
done

exec "${real_tool}" "\${args[@]}"
EOF
  chmod 755 "$wrapper_path"
}

ensure_mingw_clang_wrappers() {
  local wrapper_root="${BUILD_DIR}/mingw-clang-wrapper"
  local wrapper_bin="${wrapper_root}/bin"
  local tool=""

  [[ "$TARGET_KIND" == "mingw" ]] || return 0

  log "Preparing MinGW clang flag wrappers"
  rm -rf "$wrapper_root"
  mkdir -p "$wrapper_bin"

  write_mingw_clang_wrapper \
    "${wrapper_bin}/${TARGET_TRIPLE}-clang-gcc" \
    "${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-gcc"
  write_mingw_clang_wrapper \
    "${wrapper_bin}/${TARGET_TRIPLE}-clang-g++" \
    "${LLVM_ROOT}/bin/${TARGET_TRIPLE}-clang-g++"

  write_exec_wrapper "${wrapper_bin}/clang" "${LLVM_ROOT}/bin/clang"
  write_exec_wrapper "${wrapper_bin}/clang++" "${LLVM_ROOT}/bin/clang++"
  write_mingw_ar_wrapper "${wrapper_bin}/llvm-ar" "${LLVM_ROOT}/bin/llvm-ar"

  for tool in llvm-nm llvm-readobj llvm-readelf llvm-strip; do
    ln -sf "${LLVM_ROOT}/bin/${tool}" "${wrapper_bin}/${tool}"
  done

  CLANG_BASE_PATH="$wrapper_root"
}

write_gn_args() {
  local gn_target_cpu="$1"
  local gn_target_os="$2"
  local gn_args_file="${V8_BUILD_DIR}/args.gn"
  local sysroot=""

  mkdir -p "$V8_BUILD_DIR"

  if [[ "$TARGET_KIND" == "linux" ]]; then
    sysroot="${SYSROOT:-/opt/sysroot/${TARGET_TRIPLE}}"
    [[ -d "$sysroot" ]] || die "missing sysroot: ${sysroot}"
  fi

  cat >"$gn_args_file" <<EOF
is_debug = false
is_component_build = true
is_clang = true
target_cpu = $(gn_quote "$gn_target_cpu")
target_os = $(gn_quote "$gn_target_os")
v8_target_cpu = $(gn_quote "$gn_target_cpu")
v8_enable_i18n_support = false
v8_use_perfetto = false
v8_use_external_startup_data = false
v8_enable_pointer_compression = true
v8_enable_sandbox = false
treat_warnings_as_errors = false
clang_use_chrome_plugins = false
clang_base_path = $(gn_quote "${CLANG_BASE_PATH:-${LLVM_ROOT}}")
use_custom_libcxx = false
target_sysroot = $(gn_quote "$sysroot")
use_sysroot = false
use_dbus = false
use_gio = false
use_glib = false
use_ozone = false
symbol_level = 0
strip_debug_info = true
develop_suit_use_external_zlib = true
develop_suit_external_zlib_prefix = $(gn_quote "${LLVMSDK_PREFIX}")
EOF

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    cat >>"$gn_args_file" <<EOF
develop_suit_mingw = true
host_toolchain = "//build/toolchain/linux:clang_x64"
win_linker_timing = false
enable_precompiled_headers = false
v8_enable_system_instrumentation = false
v8_enable_etw_stack_walking = false
EOF
  fi
}

extract_llvmsdk_archive() {
  local tmp_extract="${BUILD_DIR}/llvmsdk-extract"
  local extracted_dir=""

  [[ -f "$LLVMSDK_ARCHIVE" ]] || die "missing llvmsdk archive: ${LLVMSDK_ARCHIVE}"

  log "Extracting target llvmsdk for zlib"
  rm -rf "$tmp_extract" "$LLVMSDK_PREFIX"
  mkdir -p "$tmp_extract" "$LLVMSDK_PREFIX"
  tar -xf "$LLVMSDK_ARCHIVE" -C "$tmp_extract"

  if [[ -f "${tmp_extract}/include/zlib.h" ]]; then
    extracted_dir="$tmp_extract"
  else
    while IFS= read -r candidate; do
      extracted_dir="$(dirname "$(dirname "$candidate")")"
      break
    done < <(find "$tmp_extract" -mindepth 2 -maxdepth 3 -type f -path '*/include/zlib.h' | sort)
  fi

  [[ -n "$extracted_dir" ]] || die "could not find zlib headers in llvmsdk archive: ${LLVMSDK_ARCHIVE}"
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    [[ -f "${extracted_dir}/lib/libz.dll.a" && -f "${extracted_dir}/bin/libz.dll" ]] \
      || die "could not find zlib import/runtime library in llvmsdk archive: ${LLVMSDK_ARCHIVE}"
  else
    [[ -f "${extracted_dir}/lib/libz.so" || -f "${extracted_dir}/lib/libz.so.1" ]] \
      || die "could not find zlib shared library in llvmsdk archive: ${LLVMSDK_ARCHIVE}"
  fi

  cp -a "${extracted_dir}/." "$LLVMSDK_PREFIX/"
  rm -rf "$tmp_extract"
}

install_v8_headers() {
  log "Installing V8 public headers"
  mkdir -p "${SDK_PREFIX}/include"
  cp -a "${V8_SOURCE_DIR}/include/." "${SDK_PREFIX}/include/"
}

install_v8_libraries() {
  local library=""
  local found=0

  log "Installing V8 shared libraries"
  mkdir -p "${SDK_PREFIX}/lib"
  while IFS= read -r library; do
    cp -a "$library" "${SDK_PREFIX}/lib/"
    found=1
  done < <(
    find "$V8_BUILD_DIR" -maxdepth 1 -type f \( \
      -name 'libv8*.so' -o -name 'libv8*.so.*' -o -name 'libcppgc*.so' -o -name 'libcppgc*.so.*' -o \
      -name 'libv8*.dll' -o -name 'libcppgc*.dll' -o -name 'libv8*.dll.a' -o -name 'libcppgc*.dll.a' \
    \) | sort
  )

  [[ "$found" -eq 1 ]] || die "no V8 shared libraries produced in ${V8_BUILD_DIR}"
}

install_external_zlib_libraries() {
  if [[ "$TARGET_KIND" == "mingw" ]]; then
    log "Installing target zlib runtime from llvmsdk"
    mkdir -p "${SDK_PREFIX}/bin" "${SDK_PREFIX}/lib"
    cp -a "${LLVMSDK_PREFIX}/bin/libz.dll" "${SDK_PREFIX}/bin/"
    cp -a "${LLVMSDK_PREFIX}/lib/libz.dll.a" "${SDK_PREFIX}/lib/"
    return 0
  fi

  if [[ "$TARGET_KIND" == "linux" ]]; then
    log "Installing target zlib runtime from llvmsdk"
    rm -f "${SDK_PREFIX}/lib"/libchrome_zlib*.so* "${SDK_PREFIX}/lib"/libz.so*
    [[ -e "${LLVMSDK_PREFIX}/lib/libz.so.1" ]] || die "missing llvmsdk zlib runtime: ${LLVMSDK_PREFIX}/lib/libz.so.1"
    cp -a "${LLVMSDK_PREFIX}/lib"/libz.so* "${SDK_PREFIX}/lib/"
  fi
}

copy_linux_cxx_runtime_libraries() {
  local runtime_dir="${LLVM_ROOT}/lib/${TARGET_TRIPLE}"
  local library_name=""

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  [[ -d "$runtime_dir" ]] || die "missing LLVM C++ runtime directory: ${runtime_dir}"

  log "Installing LLVM C++ runtime libraries"
  mkdir -p "${SDK_PREFIX}/lib"
  for library_name in \
      libc++.so libc++.so.1 libc++.so.1.0 \
      libc++abi.so libc++abi.so.1 libc++abi.so.1.0 \
      libunwind.so libunwind.so.1 libunwind.so.1.0; do
    [[ -e "${runtime_dir}/${library_name}" ]] || die "missing LLVM C++ runtime library: ${runtime_dir}/${library_name}"
    cp -a "${runtime_dir}/${library_name}" "${SDK_PREFIX}/lib/"
  done
}

copy_mingw_cxx_runtime_libraries() {
  local runtime_root="/opt/${TARGET_TRIPLE}"
  local runtime_name=""

  [[ "$TARGET_KIND" == "mingw" ]] || return 0
  [[ -d "$runtime_root" ]] || die "missing MinGW runtime root: ${runtime_root}"

  log "Installing MinGW C++ runtime libraries"
  mkdir -p "${SDK_PREFIX}/bin" "${SDK_PREFIX}/lib"
  for runtime_name in libc++ libunwind; do
    [[ -f "${runtime_root}/bin/${runtime_name}.dll" ]] \
      || die "missing MinGW runtime DLL: ${runtime_root}/bin/${runtime_name}.dll"
    [[ -f "${runtime_root}/lib/${runtime_name}.dll.a" ]] \
      || die "missing MinGW runtime import library: ${runtime_root}/lib/${runtime_name}.dll.a"
    cp -a "${runtime_root}/bin/${runtime_name}.dll" "${SDK_PREFIX}/bin/"
    cp -a "${runtime_root}/lib/${runtime_name}.dll.a" "${SDK_PREFIX}/lib/"
  done
}

remove_unneeded_linux_atomic_runtime_dependency() {
  local file_path=""
  local needed=""

  [[ "$TARGET_KIND" == "linux" ]] || return 0
  require_command patchelf

  rm -f "${SDK_PREFIX}/lib"/libatomic.so*
  while IFS= read -r file_path; do
    needed="$(patchelf --print-needed "$file_path" 2>/dev/null || true)"
    if grep -qx 'libatomic.so.1' <<<"$needed"; then
      log "Removing unused libatomic dependency from ${file_path#${SDK_PREFIX}/}"
      patchelf --remove-needed libatomic.so.1 "$file_path"
    fi
  done < <(find "$SDK_PREFIX" -type f \( -perm -0100 -o -name '*.so' -o -name '*.so.*' \) | sort)
}

install_v8_tools() {
  local d8_name="d8"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    d8_name="d8.exe"
  fi

  log "Installing V8 d8 shell"
  mkdir -p "${SDK_PREFIX}/bin"
  [[ -f "${V8_BUILD_DIR}/${d8_name}" ]] || die "missing V8 d8 shell: ${V8_BUILD_DIR}/${d8_name}"
  cp -f "${V8_BUILD_DIR}/${d8_name}" "${SDK_PREFIX}/bin/"
}

install_v8_metadata() {
  local libs="-lv8 -lv8_libplatform -lv8_libbase"
  local system_libs="-ldl -pthread"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    system_libs="-lwinmm -ldbghelp -lws2_32 -lz"
  fi

  log "Installing V8 package metadata"
  mkdir -p "${SDK_PREFIX}/lib/pkgconfig" "${SDK_PREFIX}/lib/cmake/V8"

  render_template "${TEMPLATE_DIR}/v8.pc.in" "${SDK_PREFIX}/lib/pkgconfig/v8.pc" \
    "SDK_PREFIX=${SDK_PREFIX}" \
    "V8_VERSION=${V8_VERSION}" \
    "V8_LIBS=${libs} ${system_libs}"

  render_template "${TEMPLATE_DIR}/V8Config.cmake.in" "${SDK_PREFIX}/lib/cmake/V8/V8Config.cmake" \
    "V8_VERSION=${V8_VERSION}" \
    "V8_SYSTEM_LIBS=${system_libs// /;}"
}

validate_v8() {
  local d8_name="d8"

  if [[ "$TARGET_KIND" == "mingw" ]]; then
    d8_name="d8.exe"
  fi

  [[ -f "${SDK_PREFIX}/include/v8.h" ]] || die "missing V8 public header"
  [[ -f "${SDK_PREFIX}/include/libplatform/libplatform.h" ]] || die "missing V8 libplatform header"
  [[ -f "${SDK_PREFIX}/bin/${d8_name}" ]] || die "missing V8 d8 shell"
  [[ -f "${SDK_PREFIX}/lib/pkgconfig/v8.pc" ]] || die "missing V8 pkg-config file"
  [[ -f "${SDK_PREFIX}/lib/cmake/V8/V8Config.cmake" ]] || die "missing V8 CMake config"
  find "${SDK_PREFIX}/lib" -maxdepth 1 \( -name 'libv8*.so' -o -name 'libv8*.so.*' -o -name 'libv8*.dll' -o -name 'libv8*.dll.a' \) | grep -q . \
    || die "missing V8 shared libraries"
}

ARCH="${ARCH:-}"
TARGET_KIND="${TARGET_KIND:-linux}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
V8_VERSION="${V8_VERSION:-11.6.189.4}"
JOBS="${JOBS:-4}"
GCLIENT_JOBS="${GCLIENT_JOBS:-2}"
SDK_PREFIX="${SDK_PREFIX:-/opt/v8-${V8_VERSION}-${TARGET_TRIPLE}}"
BUILD_DIR="${BUILD_DIR:-/work/build}"
LLVM_ROOT="${LLVM_ROOT:-/opt/llvm-${LLVM_VERSION}}"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-/work/depot_tools}"
LLVMSDK_ARCHIVE="${LLVMSDK_ARCHIVE:-}"
LLVMSDK_PREFIX="${LLVMSDK_PREFIX:-${BUILD_DIR}/llvmsdk-${TARGET_TRIPLE}}"

case "${TARGET_KIND}:${ARCH}" in
  linux:x86_64|linux:aarch64|linux:riscv64|linux:loongarch64|mingw:x86_64) ;;
  *) die "container_v8 currently supports x86_64/aarch64/riscv64/loongarch64 Linux and experimental x86_64 MinGW" ;;
esac
[[ -n "$TARGET_TRIPLE" ]] || die "TARGET_TRIPLE is required"
[[ -d "$LLVM_ROOT" ]] || die "missing LLVM root: ${LLVM_ROOT}"
[[ -d "$SDK_PREFIX" ]] || die "missing V8 package prefix: ${SDK_PREFIX}"
[[ -d "$DEPOT_TOOLS_DIR" ]] || die "missing depot_tools: ${DEPOT_TOOLS_DIR}"

require_command git
require_command python3
require_command pkg-config
require_command tar

export PATH="${DEPOT_TOOLS_DIR}:${LLVM_ROOT}/bin:${PATH}"
export DEPOT_TOOLS_UPDATE=0
export GCLIENT_PY3=1

[[ -x "${DEPOT_TOOLS_DIR}/ensure_bootstrap" ]] || die "missing depot_tools ensure_bootstrap"
"${DEPOT_TOOLS_DIR}/ensure_bootstrap"

require_command ninja

DEP_SOURCE_DIR="${BUILD_DIR}/src"
V8_SOURCE_DIR="${DEP_SOURCE_DIR}/v8"
V8_BUILD_DIR="${BUILD_DIR}/out/${TARGET_TRIPLE}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/work/mount_root/templates}"
PATCH_DIR="${PATCH_DIR:-/work/mount_root/patch}"

gn_target_cpu="$(target_cpu_for_gn)"
gn_target_os="$(target_os_for_gn)"

ensure_v8_checkout
ensure_lastchange_timestamp
apply_v8_patches
ensure_host_gn
require_command gn
require_host_gn_from_source
extract_llvmsdk_archive
ensure_mingw_clang_wrappers

write_gn_args "$gn_target_cpu" "$gn_target_os"

log "Configuring V8 with GN"
(cd "$V8_SOURCE_DIR" && gn gen "$V8_BUILD_DIR")

log "Building V8 shared libraries and d8"
ninja -C "$V8_BUILD_DIR" -j "$JOBS" d8

if [[ "$TARGET_KIND" == "linux" && "$ARCH" == "x86_64" ]]; then
  "${V8_BUILD_DIR}/d8" -e "if (6 * 7 !== 42) throw new Error('bad arithmetic')"
else
  log "Skipping d8 smoke test for non-native target ${TARGET_TRIPLE}"
fi

install_v8_headers
install_v8_libraries
install_external_zlib_libraries
copy_linux_cxx_runtime_libraries
copy_mingw_cxx_runtime_libraries
remove_unneeded_linux_atomic_runtime_dependency
install_v8_tools
install_v8_metadata
validate_v8
patch_linux_elf_rpaths "$SDK_PREFIX" "$TARGET_KIND"

render_template "${TEMPLATE_DIR}/README.v8.in" "${SDK_PREFIX}/README.v8" \
  "TARGET_TRIPLE=${TARGET_TRIPLE}" \
  "V8_VERSION=${V8_VERSION}" \
  "LLVM_VERSION=${LLVM_VERSION}"

log "V8 package ready: ${SDK_PREFIX}"
