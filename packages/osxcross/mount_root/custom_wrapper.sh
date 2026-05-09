#!/usr/bin/env bash

set -euo pipefail

SHELL_TOOLS_DIR="${SHELL_TOOLS_DIR:-/work/shell_tools}"
source "${SHELL_TOOLS_DIR}/tools.sh"

WRAPPER_SRC="${SRC_ROOT}/osxcross-wrapper"
WRAPPER_UPSTREAM="/work/upstream/osxcross/wrapper"
MACOS_SDK_VERSION="${MACOS_SDK_VERSION:-13.3}"
OSXCROSS_VERSION="${OSXCROSS_VERSION:-develop_suit}"
OSXCROSS_TARGET="${OSXCROSS_TARGET:-darwin22.4}"
OSXCROSS_OSX_VERSION_MIN="${OSXCROSS_OSX_VERSION_MIN:-13.0}"
OSXCROSS_LINKER_VERSION="${OSXCROSS_LINKER_VERSION:-711}"
OSXCROSS_ARCHS="${OSXCROSS_ARCHS:-arm64 arm64e x86_64 x86_64h}"
OSXCROSS_TARGET_ARCH="${OSXCROSS_TARGET_ARCH:-${OSXCROSS_ARCHS%% *}}"
OSXCROSS_TARGET_TRIPLE="${OSXCROSS_TARGET_ARCH}-apple-${OSXCROSS_TARGET}"
WRAPPER_RUNTIME_PREFIX="${LLVM_SDK_ROOT:-${DEPS_USR:-}}"

[[ -f "${WRAPPER_UPSTREAM}/Makefile" ]] || die "missing upstream osxcross wrapper source"
[[ -n "$WRAPPER_RUNTIME_PREFIX" ]] || die "LLVM_SDK_ROOT or DEPS_USR is required for wrapper runtime libraries"
[[ -d "${WRAPPER_RUNTIME_PREFIX}/lib" ]] || die "missing wrapper runtime library directory: ${WRAPPER_RUNTIME_PREFIX}/lib"

rm -rf "$WRAPPER_SRC"
cp -a "$WRAPPER_UPSTREAM" "$WRAPPER_SRC"

echo "-- building osxcross wrapper"
echo "-- osxcross target: ${OSXCROSS_TARGET_TRIPLE}"
echo "-- osxcross wrapper archs: ${OSXCROSS_ARCHS}"

(
  cd "$WRAPPER_SRC"
  SUPPORTED_ARCHS="$OSXCROSS_ARCHS" make clean
  PLATFORM=Linux \
  CXX="$CXX" \
  SUPPORTED_ARCHS="$OSXCROSS_ARCHS" \
  TARGET="$OSXCROSS_TARGET" \
  VERSION="$OSXCROSS_VERSION" \
  OSX_VERSION_MIN="$OSXCROSS_OSX_VERSION_MIN" \
  LINKER_VERSION="$OSXCROSS_LINKER_VERSION" \
  LIBLTO_PATH="${OUT_DIR}/lib" \
  BUILD_DIR="$BUILD_ROOT" \
  ADDITIONAL_CXXFLAGS="-isystem quirks/include" \
  LDFLAGS="-Wl,-rpath,'\$\$ORIGIN/../lib' -Wl,--enable-new-dtags" \
  make wrapper -j "$JOBS"
)

mkdir -p "${OUT_DIR}/bin" "${OUT_DIR}/lib"
install -m 0755 "${WRAPPER_SRC}/wrapper" "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-wrapper"

shopt -s nullglob
wrapper_runtime_libs=(
  "${WRAPPER_RUNTIME_PREFIX}/lib/libc++.so"*
  "${WRAPPER_RUNTIME_PREFIX}/lib/libc++abi.so"*
  "${WRAPPER_RUNTIME_PREFIX}/lib/libunwind.so"*
)
shopt -u nullglob
[[ "${#wrapper_runtime_libs[@]}" -gt 0 ]] || die "missing wrapper runtime libraries under: ${WRAPPER_RUNTIME_PREFIX}/lib"
cp -a "${wrapper_runtime_libs[@]}" "${OUT_DIR}/lib/"

(
  cd "${OUT_DIR}/bin"

  for tool in clang clang++ clang++-libc++ clang++-stdc++ clang++-gstdc++ cc c++; do
    for arch in $OSXCROSS_ARCHS; do
      ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "${arch}-apple-${OSXCROSS_TARGET}-${tool}"
    done
    case " ${OSXCROSS_ARCHS} " in
      *" arm64 "*)
        ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "aarch64-apple-${OSXCROSS_TARGET}-${tool}"
        ;;
    esac
  done

  for tool in clang clang++ clang++-libc++ clang++-stdc++ clang++-gstdc++; do
    case " ${OSXCROSS_ARCHS} " in
      *" i386 "*) ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "o32-${tool}" ;;
    esac
    case " ${OSXCROSS_ARCHS} " in
      *" x86_64 "*) ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "o64-${tool}" ;;
    esac
    case " ${OSXCROSS_ARCHS} " in
      *" x86_64h "*) ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "o64h-${tool}" ;;
    esac
    case " ${OSXCROSS_ARCHS} " in
      *" arm64 "*) ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "oa64-${tool}" ;;
    esac
    case " ${OSXCROSS_ARCHS} " in
      *" arm64e "*) ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "oa64e-${tool}" ;;
    esac
  done

  for tool in osxcross osxcross-conf osxcross-env osxcross-cmp osxcross-man pkg-config sw_vers xcrun xcodebuild dsymutil; do
    ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "$tool"
    for arch in $OSXCROSS_ARCHS; do
      ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "${arch}-apple-${OSXCROSS_TARGET}-${tool}"
    done
    case " ${OSXCROSS_ARCHS} " in
      *" arm64 "*)
        ln -sf "${OSXCROSS_TARGET_TRIPLE}-wrapper" "aarch64-apple-${OSXCROSS_TARGET}-${tool}"
        ;;
    esac
  done
)

file "${OUT_DIR}/bin/${OSXCROSS_TARGET_TRIPLE}-wrapper" || true
echo "-- osxcross wrapper build ok: ${OUT_DIR}"
