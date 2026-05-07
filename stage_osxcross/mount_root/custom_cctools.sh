#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

CCTOOLS_SRC="${SRC_ROOT}/cctools-port"
CCTOOLS_BUILD="${BUILD_ROOT}/build/cctools"
MACOS_SDK_VERSION="${MACOS_SDK_VERSION:-13.3}"
OSXCROSS_TARGET="${OSXCROSS_TARGET:-darwin22.4}"
OSXCROSS_ARCHS="${OSXCROSS_ARCHS:-arm64 arm64e x86_64 x86_64h}"
OSXCROSS_TARGET_ARCH="${OSXCROSS_TARGET_ARCH:-${OSXCROSS_ARCHS%% *}}"
OSXCROSS_TARGET_TRIPLE="${OSXCROSS_TARGET_ARCH}-apple-${OSXCROSS_TARGET}"

[[ -d "/work/upstream/cctools-port/cctools" ]] || die "missing upstream cctools-port source"
[[ -f "${OUT_DIR}/include/tapi/tapi.h" ]] || die "missing libtapi headers: ${OUT_DIR}/include/tapi/tapi.h"
[[ -f "${OUT_DIR}/lib/libtapi.so" ]] || die "missing libtapi library: ${OUT_DIR}/lib/libtapi.so"
[[ -f "${OUT_DIR}/include/llvm-c/lto.h" ]] || die "missing libLTO header: ${OUT_DIR}/include/llvm-c/lto.h"
[[ -f "${OUT_DIR}/lib/libLTO.so" ]] || die "missing libLTO library: ${OUT_DIR}/lib/libLTO.so"
[[ -f "${OUT_DIR}/include/xar/xar.h" ]] || die "missing xar headers: ${OUT_DIR}/include/xar/xar.h"
[[ -f "${OUT_DIR}/lib/libxar.a" || -f "${OUT_DIR}/lib/libxar.so" ]] || die "missing xar library under ${OUT_DIR}/lib"

mkdir -p "$CCTOOLS_BUILD"
cp -a /work/upstream/cctools-port "$CCTOOLS_SRC"

echo "-- building cctools"
echo "-- macOS SDK version hint: ${MACOS_SDK_VERSION}"
echo "-- osxcross target: ${OSXCROSS_TARGET_TRIPLE}"
echo "-- osxcross arch symlinks: ${OSXCROSS_ARCHS}"

TARGET_CPPFLAGS="-I${DEPS_USR}/include -I${DEPS_USR}/include/libxml2"
TARGET_CFLAGS="--sysroot=${SYSROOT} -O2 -w ${TARGET_CPPFLAGS}"
TARGET_CXXFLAGS="--sysroot=${SYSROOT} -O2 -w ${TARGET_CPPFLAGS}"
TARGET_LDFLAGS="--sysroot=${SYSROOT} -L${OUT_DIR}/lib -L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${OUT_DIR}/lib -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

cat >"${BUILD_TOOLS}/llvm-config" <<EOF
#!/usr/bin/env sh
case "\$1" in
  --includedir)
    echo "${OUT_DIR}/include"
    ;;
  --libdir)
    echo "${OUT_DIR}/lib"
    ;;
  --version)
    echo "${LLVM_VERSION:-18.1.8}"
    ;;
  *)
    echo "usage: llvm-config [--includedir|--libdir|--version]" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BUILD_TOOLS}/llvm-config"

cd "$CCTOOLS_BUILD"
CC="$CC" \
CXX="$CXX" \
AR="$AR" \
RANLIB="$RANLIB" \
STRIP="$STRIP" \
NM="$NM" \
CFLAGS="$TARGET_CFLAGS" \
CXXFLAGS="$TARGET_CXXFLAGS" \
CPPFLAGS="$TARGET_CPPFLAGS" \
LDFLAGS="$TARGET_LDFLAGS" \
LIBS="-lxml2 -lz -lm" \
"${CCTOOLS_SRC}/cctools/configure" \
  --prefix="$OUT_DIR" \
  --build=x86_64-unknown-linux-gnu \
  --host="$TARGET_TRIPLE" \
  --target="$OSXCROSS_TARGET_TRIPLE" \
  --with-llvm-config="${BUILD_TOOLS}/llvm-config" \
  --with-libtapi="$OUT_DIR" \
  --with-libxar="$OUT_DIR"

make -j"$JOBS"
make install -j"$JOBS"

(
  cd "${OUT_DIR}/bin"
  for tool in "${OSXCROSS_TARGET_TRIPLE}"-*; do
    [[ -e "$tool" ]] || continue
    for arch in $OSXCROSS_ARCHS; do
      [[ "$arch" != "$OSXCROSS_TARGET_ARCH" ]] || continue
      ln -sf "$tool" "${tool/#${OSXCROSS_TARGET_ARCH}-apple-${OSXCROSS_TARGET}/${arch}-apple-${OSXCROSS_TARGET}}"
    done
  done
  if [[ -e "x86_64-apple-${OSXCROSS_TARGET}-lipo" ]]; then
    ln -sf "x86_64-apple-${OSXCROSS_TARGET}-lipo" lipo
  elif [[ -e "${OSXCROSS_TARGET_TRIPLE}-lipo" ]]; then
    ln -sf "${OSXCROSS_TARGET_TRIPLE}-lipo" lipo
  fi
)

file "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-ld" "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-ar" || true
echo "-- cctools build ok: ${OUT_DIR}"
