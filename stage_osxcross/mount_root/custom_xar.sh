#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

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

cat >"${BUILD_TOOLS}/xml2-config" <<EOF
#!/usr/bin/env sh
case "\$1" in
  --version)
    if [ -f "${DEPS_USR}/lib/pkgconfig/libxml-2.0.pc" ]; then
      awk -F': *' '/^Version:/ { print \$2; exit }' "${DEPS_USR}/lib/pkgconfig/libxml-2.0.pc"
    elif [ -f "${DEPS_USR}/lib64/pkgconfig/libxml-2.0.pc" ]; then
      awk -F': *' '/^Version:/ { print \$2; exit }' "${DEPS_USR}/lib64/pkgconfig/libxml-2.0.pc"
    else
      echo 2.6.11
    fi
    ;;
  --cflags)
    echo -I"${DEPS_USR}/include/libxml2"
    ;;
  --libs)
    echo -L"${DEPS_USR}/lib" -L"${DEPS_USR}/lib64" -lxml2 -lz -lm
    ;;
  *)
    echo "usage: xml2-config [--version|--cflags|--libs]" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BUILD_TOOLS}/xml2-config"

TARGET_CPPFLAGS="-I${DEPS_USR}/include -I${DEPS_USR}/include/libxml2"
TARGET_CFLAGS="--sysroot=${SYSROOT} -O2 -w ${TARGET_CPPFLAGS}"
TARGET_LDFLAGS="--sysroot=${SYSROOT} -L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

echo "-- building xar"

cd "$XAR_BUILD"
CC="$CC" \
AR="$AR" \
RANLIB="$RANLIB" \
STRIP="$STRIP" \
CFLAGS="$TARGET_CFLAGS" \
CPPFLAGS="$TARGET_CPPFLAGS" \
LDFLAGS="$TARGET_LDFLAGS" \
"${XAR_SRC}/xar/configure" \
  --prefix="$OUT_DIR" \
  --build=x86_64-unknown-linux-gnu \
  --host="$TARGET_TRIPLE" \
  --with-xml2-config="${BUILD_TOOLS}/xml2-config" \
  --without-bzip2

make -j"$JOBS"
make install

file "${OUT_DIR}/bin/xar" "${OUT_DIR}/lib/libxar.a" || true
echo "-- xar build ok: ${OUT_DIR}"
