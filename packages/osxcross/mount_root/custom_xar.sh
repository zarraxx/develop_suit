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

case "$TARGET_TRIPLE" in
  loongarch64-unknown-linux-gnu)
    (
      cd "$XAR_SRC"
      patch -p1 < "${PATCH_DIR}/xar-config-sub-loongarch64.patch"
    )
    ;;
esac

render_template "${TEMPLATE_DIR}/xml2-config.in" "${BUILD_TOOLS}/xml2-config" \
  "DEPS_USR=${DEPS_USR}"
chmod +x "${BUILD_TOOLS}/xml2-config"

TARGET_CPPFLAGS="-I${DEPS_USR}/include -I${DEPS_USR}/include/libxml2"
TARGET_CFLAGS="--sysroot=${SYSROOT} -O2 -w ${TARGET_CPPFLAGS}"
TARGET_LDFLAGS="--sysroot=${SYSROOT} -L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"
TARGET_LIBS="-pthread -ldl"

echo "-- building xar"

cd "$XAR_BUILD"
CC="$CC" \
AR="$AR" \
RANLIB="$RANLIB" \
STRIP="$STRIP" \
CFLAGS="$TARGET_CFLAGS" \
CPPFLAGS="$TARGET_CPPFLAGS" \
LDFLAGS="$TARGET_LDFLAGS" \
LIBS="$TARGET_LIBS" \
"${XAR_SRC}/xar/configure" \
  --prefix="$OUT_DIR" \
  --build=x86_64-unknown-linux-gnu \
  --host="$TARGET_TRIPLE" \
  --with-xml2-config="${BUILD_TOOLS}/xml2-config" \
  --with-bzip2 \
  "--with-lzma=${DEPS_USR}"

make -j"$JOBS"
make install
find "${OUT_DIR}/lib" -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -delete

file "${OUT_DIR}/bin/xar" "${OUT_DIR}/lib/libxar.so" || true
echo "-- xar build ok: ${OUT_DIR}"
