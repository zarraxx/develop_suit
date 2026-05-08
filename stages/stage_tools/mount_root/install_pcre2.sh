#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: install_pcre2.sh <source-dir> <build-dir> <out-dir>" >&2
  exit 1
fi

src_dir="$1"
build_dir="$2"
out_dir="$3"

mkdir -p \
  "${out_dir}/usr/bin" \
  "${out_dir}/usr/include" \
  "${out_dir}/usr/lib" \
  "${out_dir}/usr/lib/pkgconfig"

cp -a "${build_dir}/.libs/libpcre2-8.so"* "${out_dir}/usr/lib/"
cp -a "${build_dir}/src/pcre2.h" "${out_dir}/usr/include/"
cp -a "${src_dir}/src/pcre2posix.h" "${out_dir}/usr/include/"
cp -a "${build_dir}/libpcre2-8.pc" "${out_dir}/usr/lib/pkgconfig/"
cp -a "${build_dir}/pcre2-config" "${out_dir}/usr/bin/"
