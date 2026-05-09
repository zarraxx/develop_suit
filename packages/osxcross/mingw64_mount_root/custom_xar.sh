#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

XAR_SRC="${SRC_ROOT}/xar"
XAR_BUILD="${BUILD_ROOT}/build/xar"

[[ -d "/work/upstream/xar/xar" ]] || die "missing upstream xar source"

rm -rf "$XAR_SRC" "$XAR_BUILD"
mkdir -p "$XAR_BUILD"
cp -a /work/upstream/xar "$XAR_SRC"
(
  cd "$XAR_SRC"
  patch -p1 < "${PATCH_DIR}/xar-mingw-winsock-byteorder.patch"
  patch -p1 < "${PATCH_DIR}/xar-mingw-posix-compat.patch"
  patch -p1 < "${PATCH_DIR}/xar-mingw-stat-compat.patch"
)

render_template "${TEMPLATE_DIR}/xml2-config.in" "${BUILD_TOOLS}/xml2-config" \
  "DEPS_USR=${DEPS_USR}"
chmod +x "${BUILD_TOOLS}/xml2-config"

TARGET_CPPFLAGS="-I${DEPS_USR}/include -I${DEPS_USR}/include/libxml2 -Duid_t=uint32_t -Dgid_t=uint32_t -include ${XAR_SRC}/xar/lib/xar_mingw_compat.h"
TARGET_CFLAGS="-O2 -w ${TARGET_CPPFLAGS}"
TARGET_LDFLAGS="-L${DEPS_USR}/lib -L${OUT_DIR}/lib"
TARGET_LIBS="-lxml2 -llzma -lbz2 -lz -lws2_32 -lbcrypt"

echo "-- building MinGW xar"

cd "$XAR_BUILD"
CC="$CC" \
AR="$AR" \
RANLIB="$RANLIB" \
STRIP="$STRIP" \
CFLAGS="$TARGET_CFLAGS" \
CPPFLAGS="$TARGET_CPPFLAGS" \
LDFLAGS="$TARGET_LDFLAGS" \
LIBS="$TARGET_LIBS" \
ac_cv_sizeof_uid_t=4 \
ac_cv_sizeof_gid_t=4 \
ac_cv_sizeof_ino_t=8 \
ac_cv_sizeof_dev_t=8 \
ac_cv_func_asprintf=no \
"${XAR_SRC}/xar/configure" \
  --prefix="$OUT_DIR" \
  --build=x86_64-unknown-linux-gnu \
  --host="$TARGET_TRIPLE" \
  --with-xml2-config="${BUILD_TOOLS}/xml2-config" \
  --with-bzip2 \
  "--with-lzma=${DEPS_USR}"

make -j"$JOBS"
make install
find "${OUT_DIR}/lib" -maxdepth 1 -name '*.la' -delete

shopt -s nullglob
xar_bins=("${OUT_DIR}/bin/xar.exe" "${OUT_DIR}/bin/libxar"*.dll)
xar_libs=("${OUT_DIR}/lib/libxar"*.dll.a)
shopt -u nullglob
[[ "${#xar_bins[@]}" -gt 0 ]] || die "xar did not install Windows binaries"
[[ "${#xar_libs[@]}" -gt 0 ]] || die "xar did not install import libraries"

file "${xar_bins[@]}" "${xar_libs[@]}" || true
echo "-- MinGW xar build ok: ${OUT_DIR}"
