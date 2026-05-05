#!/bin/sh
set -eu

target_machine_name() {
  case "$1" in
    x86_64-unknown-linux-gnu)
      printf '%s\n' "Advanced Micro Devices X86-64"
      ;;
    aarch64-unknown-linux-gnu)
      printf '%s\n' "AArch64"
      ;;
    riscv64-unknown-linux-gnu)
      printf '%s\n' "RISC-V"
      ;;
    loongarch64-unknown-linux-gnu)
      printf '%s\n' "LoongArch"
      ;;
    *)
      return 1
      ;;
  esac
}

target_cpu_family() {
  case "$1" in
    x86_64-unknown-linux-gnu)
      printf '%s\n' "x86_64"
      ;;
    aarch64-unknown-linux-gnu)
      printf '%s\n' "aarch64"
      ;;
    riscv64-unknown-linux-gnu)
      printf '%s\n' "riscv64"
      ;;
    loongarch64-unknown-linux-gnu)
      printf '%s\n' "loongarch64"
      ;;
    *)
      return 1
      ;;
  esac
}

native_triple() {
  machine="$(uname -m)"

  case "$machine" in
    x86_64)
      printf '%s\n' "x86_64-unknown-linux-gnu"
      ;;
    aarch64)
      printf '%s\n' "aarch64-unknown-linux-gnu"
      ;;
    riscv64)
      printf '%s\n' "riscv64-unknown-linux-gnu"
      ;;
    loongarch64)
      printf '%s\n' "loongarch64-unknown-linux-gnu"
      ;;
    *)
      echo "unsupported native machine for ldd smoke test: ${machine}" >&2
      return 1
      ;;
  esac
}

check_machine() {
  output_file="$1"
  triple="$2"
  expected_machine="$(target_machine_name "$triple")"
  actual_machine="$("${READELF_BIN}" -h "$output_file" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n 1)"

  if [ "$actual_machine" != "$expected_machine" ]; then
    echo "unexpected ELF machine for ${output_file}: ${actual_machine}" >&2
    echo "expected: ${expected_machine}" >&2
    exit 1
  fi
}

check_native_ldd() {
  output_file="$1"
  ldd_log="$2"

  echo "-- ldd native ELF: ${output_file}"
  ldd "$output_file" >"$ldd_log"
  cat "$ldd_log"

  if grep -Eq 'not found|not a dynamic executable|No such file' "$ldd_log"; then
    echo "unexpected ldd output for ${output_file}" >&2
    exit 1
  fi
}

write_cmake_toolchain() {
  triple="$1"
  toolchain_file="$2"
  processor="$(target_cpu_family "$triple")"

  cat >"$toolchain_file" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${processor})
set(CMAKE_SYSROOT /opt/sysroot/${triple})
set(CMAKE_C_COMPILER /opt/llvm-18.1.8/bin/${triple}-clang)
set(CMAKE_CXX_COMPILER /opt/llvm-18.1.8/bin/${triple}-clang++)
set(CMAKE_AR /opt/llvm-18.1.8/bin/${triple}-ar)
set(CMAKE_RANLIB /opt/llvm-18.1.8/bin/${triple}-ranlib)
set(CMAKE_STRIP /opt/llvm-18.1.8/bin/${triple}-strip)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF
}

write_meson_cross_file() {
  triple="$1"
  cross_file="$2"
  cpu_family="$(target_cpu_family "$triple")"

  cat >"$cross_file" <<EOF
[binaries]
c = '/opt/llvm-18.1.8/bin/${triple}-clang'
cpp = '/opt/llvm-18.1.8/bin/${triple}-clang++'
ar = '/opt/llvm-18.1.8/bin/${triple}-ar'
strip = '/opt/llvm-18.1.8/bin/${triple}-strip'
pkg-config = '/usr/bin/pkg-config'

[properties]
sys_root = '/opt/sysroot/${triple}'
needs_exe_wrapper = true

[built-in options]
c_args = ['--sysroot=/opt/sysroot/${triple}']
cpp_args = ['--sysroot=/opt/sysroot/${triple}']
c_link_args = ['--sysroot=/opt/sysroot/${triple}']
cpp_link_args = ['--sysroot=/opt/sysroot/${triple}']

[host_machine]
system = 'linux'
cpu_family = '${cpu_family}'
cpu = '${cpu_family}'
endian = 'little'
EOF
}

tests_dir="${1:-/opt/stage_tools_tests}"
output_root="${2:-/opt/stage_tools_out}"

[ -d "$tests_dir" ] || {
  echo "tests directory not found: ${tests_dir}" >&2
  exit 1
}

mkdir -p "$output_root"

READELF_BIN="/opt/llvm-18.1.8/bin/llvm-readelf"
[ -x "$READELF_BIN" ] || {
  echo "llvm-readelf not found: ${READELF_BIN}" >&2
  exit 1
}

LDD_BIN="$(command -v ldd || true)"
[ -n "$LDD_BIN" ] || {
  echo "ldd not found in image" >&2
  exit 1
}

native_test_triple="$(native_triple)"

echo "== stage_tools smoke test =="
echo "-- native triple: ${native_test_triple}"

for required_tool in \
    /usr/bin/bash \
    /usr/bin/file \
    /usr/bin/git \
    /usr/bin/meson \
    /usr/bin/ninja \
    /opt/cmake3/bin/cmake \
    /opt/cmake4/bin/cmake; do
  [ -x "$required_tool" ] || {
    echo "required tool not found or not executable: ${required_tool}" >&2
    exit 1
  }
done

/usr/bin/bash --version | head -n 1
/usr/bin/git --version
/usr/bin/file --version | head -n 1
/usr/bin/meson --version
/opt/cmake3/bin/cmake --version | head -n 1
/opt/cmake4/bin/cmake --version | head -n 1

/usr/bin/bash "${tests_dir}/bash/bash-features.sh"

tmp_root="${TMPDIR:-/tmp}/stage-tools-smoke.$$"
trap 'rm -rf "${tmp_root}"' EXIT INT TERM
mkdir -p "$tmp_root"

triples="
x86_64-unknown-linux-gnu
aarch64-unknown-linux-gnu
riscv64-unknown-linux-gnu
loongarch64-unknown-linux-gnu
"

for triple in ${triples}; do
  echo "-- cmake cross build: ${triple}"
  cmake_build_dir="${tmp_root}/cmake-${triple}"
  cmake_toolchain_file="${tmp_root}/cmake-${triple}.cmake"
  write_cmake_toolchain "$triple" "$cmake_toolchain_file"

  /opt/cmake4/bin/cmake \
    -S "${tests_dir}/cmake-cross" \
    -B "$cmake_build_dir" \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$cmake_toolchain_file" \
    -DCMAKE_BUILD_TYPE=Release

  /opt/cmake4/bin/cmake --build "$cmake_build_dir"

  cp "${cmake_build_dir}/cmake_hello_c" "${output_root}/cmake-${triple}-hello-c"
  cp "${cmake_build_dir}/cmake_hello_cpp" "${output_root}/cmake-${triple}-hello-cpp"
  check_machine "${output_root}/cmake-${triple}-hello-c" "$triple"
  check_machine "${output_root}/cmake-${triple}-hello-cpp" "$triple"
  if [ "$triple" = "$native_test_triple" ]; then
    check_native_ldd "${output_root}/cmake-${triple}-hello-c" "${output_root}/cmake-${triple}-hello-c.ldd"
    check_native_ldd "${output_root}/cmake-${triple}-hello-cpp" "${output_root}/cmake-${triple}-hello-cpp.ldd"
  fi

  echo "-- meson cross build: ${triple}"
  meson_build_dir="${tmp_root}/meson-${triple}"
  meson_cross_file="${tmp_root}/meson-${triple}.ini"
  write_meson_cross_file "$triple" "$meson_cross_file"

  /usr/bin/meson setup \
    "$meson_build_dir" \
    "${tests_dir}/meson-cross" \
    --cross-file "$meson_cross_file" \
    --buildtype release

  /usr/bin/meson compile -C "$meson_build_dir"

  cp "${meson_build_dir}/meson_hello_c" "${output_root}/meson-${triple}-hello-c"
  cp "${meson_build_dir}/meson_hello_cpp" "${output_root}/meson-${triple}-hello-cpp"
  check_machine "${output_root}/meson-${triple}-hello-c" "$triple"
  check_machine "${output_root}/meson-${triple}-hello-cpp" "$triple"
  if [ "$triple" = "$native_test_triple" ]; then
    check_native_ldd "${output_root}/meson-${triple}-hello-c" "${output_root}/meson-${triple}-hello-c.ldd"
    check_native_ldd "${output_root}/meson-${triple}-hello-cpp" "${output_root}/meson-${triple}-hello-cpp.ldd"
  fi
done

echo "== stage_tools smoke test ok =="
