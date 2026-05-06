#!/bin/sh

set -eu

output_root="${1:-/opt/stage_mingw64_out}"
target_triple="x86_64-w64-windows-gnu"
toolchain_root="/opt/llvm-18.1.8"
mingw_root="/opt/${target_triple}"
cc="${toolchain_root}/bin/${target_triple}-clang-gcc"
cxx="${toolchain_root}/bin/${target_triple}-clang-g++"

[ -x "$cc" ] || {
  echo "missing compiler: $cc" >&2
  exit 1
}

[ -x "$cxx" ] || {
  echo "missing compiler: $cxx" >&2
  exit 1
}

[ -f "${cc}.cfg" ] || {
  echo "missing clang config: ${cc}.cfg" >&2
  exit 1
}

[ -d "$mingw_root" ] || {
  echo "missing target root: $mingw_root" >&2
  exit 1
}

mkdir -p "$output_root"

tmp_root="${TMPDIR:-/tmp}/stage-mingw64-smoke.$$"
trap 'rm -rf "$tmp_root"' EXIT INT TERM
mkdir -p "$tmp_root"

c_source="${tmp_root}/hello.c"
cpp_source="${tmp_root}/hello.cpp"
c_output="${output_root}/hello-c.exe"
cpp_output="${output_root}/hello-cpp.exe"

cat >"$c_source" <<'EOF'
#include <windows.h>

int main(void) {
  MessageBoxA(NULL, "hello from clang windows gnu", "stage-mingw64", MB_OK);
  return 0;
}
EOF

cat >"$cpp_source" <<'EOF'
#include <string>
#include <windows.h>

int main() {
  std::string message = "hello from clang++ windows gnu";
  MessageBoxA(NULL, message.c_str(), "stage-mingw64", MB_OK);
  return 0;
}
EOF

echo "== stage-mingw64 smoke test =="
echo "-- target triple: ${target_triple}"
echo "-- target root: ${mingw_root}"

"$cc" -O2 -o "$c_output" "$c_source" -luser32
"$cxx" -O2 -o "$cpp_output" "$cpp_source" -luser32

file "$c_output" "$cpp_output"

file "$c_output" | grep -Eq 'PE32\+.*x86-64' || {
  echo "unexpected C output file type" >&2
  exit 1
}

file "$cpp_output" | grep -Eq 'PE32\+.*x86-64' || {
  echo "unexpected C++ output file type" >&2
  exit 1
}

echo "== stage-mingw64 smoke test ok =="
