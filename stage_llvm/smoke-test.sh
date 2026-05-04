#!/bin/sh
set -eu

normalize_host_arch() {
  case "$1" in
    x86_64|amd64)
      printf '%s\n' "x86_64"
      ;;
    aarch64|arm64)
      printf '%s\n' "aarch64"
      ;;
    riscv64)
      printf '%s\n' "riscv64"
      ;;
    loongarch64)
      printf '%s\n' "loongarch64"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

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

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)

default_arch=$(normalize_host_arch "$(uname -m)")
toolchain_root="${1:-${repo_root}/dist/stage_llvm/${default_arch}/opt/llvm-18.1.8}"
output_root="${2:-}"

if [ ! -d "${toolchain_root}" ]; then
  echo "toolchain root not found: ${toolchain_root}" >&2
  echo "usage: $0 [toolchain-root] [output-dir]" >&2
  exit 1
fi

bin_dir="${toolchain_root}/bin"
[ -x "${bin_dir}/clang" ] || {
  echo "clang not found under ${bin_dir}" >&2
  exit 1
}

readelf_bin="${bin_dir}/llvm-readelf"
if [ ! -x "${readelf_bin}" ]; then
  readelf_bin="$(command -v readelf || true)"
fi
[ -n "${readelf_bin}" ] || {
  echo "could not find llvm-readelf or readelf" >&2
  exit 1
}

tmp_root="${TMPDIR:-/tmp}/stage_llvm-smoke.$$"
trap 'rm -rf "${tmp_root}"' EXIT INT TERM
mkdir -p "${tmp_root}"

if [ -z "${output_root}" ]; then
  output_root="${tmp_root}/out"
fi
mkdir -p "${output_root}"

c_source="${tmp_root}/helloworld.c"
cpp_source="${tmp_root}/helloworld.cpp"

cat >"${c_source}" <<'EOF'
#include <stdio.h>

int main(void) {
  puts("hello world from c");
  return 0;
}
EOF

cat >"${cpp_source}" <<'EOF'
#include <iostream>

int main() {
  std::cout << "hello world from c++" << '\n';
  return 0;
}
EOF

triples="
x86_64-unknown-linux-gnu
aarch64-unknown-linux-gnu
riscv64-unknown-linux-gnu
loongarch64-unknown-linux-gnu
"

echo "== stage_llvm smoke test =="
echo "-- toolchain root: ${toolchain_root}"
echo "-- output root: ${output_root}"

for triple in ${triples}; do
  expected_machine="$(target_machine_name "${triple}")"
  c_output="${output_root}/${triple}-hello-c"
  cpp_output="${output_root}/${triple}-hello-cpp"
  c_compiler="${bin_dir}/${triple}-clang"
  cpp_compiler="${bin_dir}/${triple}-clang++"

  echo "-- building ${triple} hello world"
  [ -x "${c_compiler}" ] || {
    echo "missing compiler: ${c_compiler}" >&2
    exit 1
  }
  [ -x "${cpp_compiler}" ] || {
    echo "missing compiler: ${cpp_compiler}" >&2
    exit 1
  }

  "${c_compiler}" -O2 -o "${c_output}" "${c_source}"
  "${cpp_compiler}" -O2 -o "${cpp_output}" "${cpp_source}"

  c_machine="$("${readelf_bin}" -h "${c_output}" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n 1)"
  cpp_machine="$("${readelf_bin}" -h "${cpp_output}" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n 1)"

  [ "${c_machine}" = "${expected_machine}" ] || {
    echo "unexpected C ELF machine for ${triple}: ${c_machine}" >&2
    exit 1
  }
  [ "${cpp_machine}" = "${expected_machine}" ] || {
    echo "unexpected C++ ELF machine for ${triple}: ${cpp_machine}" >&2
    exit 1
  }

  echo "   C   ${c_output} (${c_machine})"
  echo "   C++ ${cpp_output} (${cpp_machine})"
done

echo "== stage_llvm smoke test ok =="
