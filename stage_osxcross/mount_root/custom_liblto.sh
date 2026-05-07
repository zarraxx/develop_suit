#!/usr/bin/env bash

set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

LLVM_VERSION="${LLVM_VERSION:-18.1.8}"
LLVM_ARCHIVE="${LLVM_ARCHIVE:-/work/cache/llvm-project-${LLVM_VERSION}.src.tar.xz}"
LIBLTO_SRC="${SRC_ROOT}/llvm-project-${LLVM_VERSION}.src"
LIBLTO_BUILD="${BUILD_ROOT}/build/liblto"
LLVM_TARGETS="${LLVM_TARGETS:-X86;AArch64;ARM;RISCV}"
LLVM_EXPERIMENTAL_TARGETS="${LLVM_EXPERIMENTAL_TARGETS:-LoongArch}"
LIBLTO_DEP_INCLUDE="${BUILD_ROOT}/build/liblto-dep-include"

[[ -f "$LLVM_ARCHIVE" ]] || die "missing LLVM source archive: ${LLVM_ARCHIVE}"
[[ -f "${DEPS_USR}/lib/libz.so" ]] || die "missing stage_python zlib: ${DEPS_USR}/lib/libz.so"
[[ -f "${DEPS_USR}/include/zlib.h" ]] || die "missing stage_python zlib header: ${DEPS_USR}/include/zlib.h"
[[ -f "${DEPS_USR}/include/zconf.h" ]] || die "missing stage_python zlib header: ${DEPS_USR}/include/zconf.h"

mkdir -p "$LIBLTO_BUILD" "${LIBLTO_DEP_INCLUDE}/zlib"
ln -sf "${DEPS_USR}/include/zlib.h" "${LIBLTO_DEP_INCLUDE}/zlib/zlib.h"
ln -sf "${DEPS_USR}/include/zconf.h" "${LIBLTO_DEP_INCLUDE}/zlib/zconf.h"

if [[ ! -d "${LIBLTO_SRC}/llvm" ]]; then
  echo "-- extracting LLVM source: ${LLVM_ARCHIVE}"
  tar -xf "$LLVM_ARCHIVE" -C "$SRC_ROOT"
fi

[[ -d "${LIBLTO_SRC}/llvm" ]] || die "missing extracted LLVM source: ${LIBLTO_SRC}/llvm"

echo "-- building host LLVM runtime"
echo "-- LLVM version: ${LLVM_VERSION}"
echo "-- LLVM target backends: ${LLVM_TARGETS}"
echo "-- LLVM experimental target backends: ${LLVM_EXPERIMENTAL_TARGETS}"

LIBLTO_LINK_FLAGS="-L${DEPS_USR}/lib -L${DEPS_USR}/lib64 -Wl,-rpath-link,${DEPS_USR}/lib -Wl,-rpath-link,${DEPS_USR}/lib64 -Wl,-rpath-link,${SYSROOT}/usr/lib -Wl,-rpath-link,${SYSROOT}/usr/lib64 -Wl,-rpath-link,${SYSROOT}/lib -Wl,-rpath-link,${SYSROOT}/lib64"

cmake -S "${LIBLTO_SRC}/llvm" -B "$LIBLTO_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$OUT_DIR" \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_SYSROOT="$SYSROOT" \
  -DCMAKE_FIND_ROOT_PATH="${SYSROOT};${DEPS_USR}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  -DCMAKE_EXE_LINKER_FLAGS="$LIBLTO_LINK_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$LIBLTO_LINK_FLAGS" \
  -DCMAKE_AR="$AR" \
  -DCMAKE_RANLIB="$RANLIB" \
  -DCMAKE_STRIP="$STRIP" \
  -DCMAKE_NM="$NM" \
  -DCMAKE_OBJCOPY="$OBJCOPY" \
  -DPython3_EXECUTABLE="$Python3_EXECUTABLE" \
  -DLLVM_TABLEGEN="${LLVM_ROOT}/bin/llvm-tblgen" \
  -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
  -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="$LLVM_EXPERIMENTAL_TARGETS" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_ZLIB=FORCE_ON \
  -DZLIB_ROOT="$DEPS_USR" \
  -DZLIB_INCLUDE_DIR="${LIBLTO_DEP_INCLUDE}/zlib" \
  -DZLIB_LIBRARY="${DEPS_USR}/lib/libz.so" \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_FFI=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLVM_DYLIB_COMPONENTS=all \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_BENCHMARKS=OFF

cmake --build "$LIBLTO_BUILD" --target LLVM LTO -j "$JOBS"
cmake --install "$LIBLTO_BUILD" --component llvm-headers
cmake --install "$LIBLTO_BUILD" --component LLVM
cmake --install "$LIBLTO_BUILD" --component LTO

mkdir -p "${OUT_DIR}/bin"
cat >"${OUT_DIR}/bin/llvm-config" <<EOF
#!/usr/bin/env sh
prefix="\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)"
version="${LLVM_VERSION}"
targets="$(printf '%s;%s' "$LLVM_TARGETS" "$LLVM_EXPERIMENTAL_TARGETS" | tr ';' ' ')"
out=""
for arg in "\$@"; do
  case "\$arg" in
    --version) out="\$out \$version" ;;
    --prefix) out="\$out \$prefix" ;;
    --bindir) out="\$out \$prefix/bin" ;;
    --includedir) out="\$out \$prefix/include" ;;
    --libdir) out="\$out \$prefix/lib" ;;
    --host-target) out="\$out ${TARGET_TRIPLE}" ;;
    --targets-built) out="\$out \$targets" ;;
    --shared-mode) out="\$out shared" ;;
    --components) out="\$out all" ;;
    --cflags|--cppflags) out="\$out -I\$prefix/include" ;;
    --cxxflags) out="\$out -I\$prefix/include -std=c++17" ;;
    --ldflags) out="\$out -L\$prefix/lib -Wl,-rpath-link,\$prefix/lib" ;;
    --system-libs) out="\$out -lz -ldl -lpthread -lm" ;;
    --libs) out="\$out -lLLVM" ;;
    --help)
      echo "usage: llvm-config [--version|--prefix|--bindir|--includedir|--libdir|--libs|--ldflags|--system-libs|--cflags|--cxxflags|--host-target|--targets-built|--components|--shared-mode]"
      exit 0
      ;;
  esac
done
echo "\${out# }"
EOF
chmod +x "${OUT_DIR}/bin/llvm-config"

file "${OUT_DIR}/lib/libLLVM.so" "${OUT_DIR}/lib/libLTO.so" "${OUT_DIR}/include/llvm-c/lto.h" "${OUT_DIR}/bin/llvm-config" || true
echo "-- LLVM runtime build ok: ${OUT_DIR}"
