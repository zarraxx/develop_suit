cmake_minimum_required(VERSION 3.20)

project(stage_tools_external NONE)

include(ExternalProject)

set(STAGE_TOOLS_ARCH "" CACHE STRING "Target architecture")
set(STAGE_TOOLS_TARGET_TRIPLE "" CACHE STRING "Target triple")
set(STAGE_TOOLS_CACHE_DIR "/work/cache" CACHE PATH "Download cache directory")
set(STAGE_TOOLS_OUT_DIR "/work/out/${STAGE_TOOLS_ARCH}" CACHE PATH "DESTDIR output directory")
set(STAGE_TOOLS_DEPS_DIR "/work/deps/${STAGE_TOOLS_ARCH}" CACHE PATH "Copied target image dependency root")
set(STAGE_TOOLS_JOBS "1" CACHE STRING "Parallel build jobs")

if(NOT STAGE_TOOLS_ARCH)
  message(FATAL_ERROR "STAGE_TOOLS_ARCH is required")
endif()

if(NOT STAGE_TOOLS_TARGET_TRIPLE)
  message(FATAL_ERROR "STAGE_TOOLS_TARGET_TRIPLE is required")
endif()

set(STAGE_TOOLS_TOOLCHAIN_ROOT "/opt/llvm-18.1.8")
set(STAGE_TOOLS_SYSROOT "/opt/sysroot/${STAGE_TOOLS_TARGET_TRIPLE}")
set(STAGE_TOOLS_BUILD_TRIPLE "x86_64-unknown-linux-gnu")
set(STAGE_TOOLS_BUILD_SYSROOT "/opt/sysroot/${STAGE_TOOLS_BUILD_TRIPLE}")
set(STAGE_TOOLS_BUILD_CC "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_BUILD_TRIPLE}-clang")
set(STAGE_TOOLS_CC "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_TARGET_TRIPLE}-clang")
set(STAGE_TOOLS_CXX "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_TARGET_TRIPLE}-clang++")
set(STAGE_TOOLS_LD "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/ld.lld")
set(STAGE_TOOLS_AR "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_TARGET_TRIPLE}-ar")
set(STAGE_TOOLS_RANLIB "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_TARGET_TRIPLE}-ranlib")
set(STAGE_TOOLS_STRIP "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_TARGET_TRIPLE}-strip")
set(STAGE_TOOLS_NM "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_TARGET_TRIPLE}-nm")
set(STAGE_TOOLS_TARGET_CFLAGS
  "--sysroot=${STAGE_TOOLS_SYSROOT} -O2 -I${STAGE_TOOLS_OUT_DIR}/usr/include -I${STAGE_TOOLS_DEPS_DIR}/usr/include")
set(STAGE_TOOLS_GIT_CFLAGS
  "--sysroot=${STAGE_TOOLS_SYSROOT} -O2")
set(STAGE_TOOLS_BASH_CFLAGS
  "--sysroot=${STAGE_TOOLS_SYSROOT} -O2")
set(STAGE_TOOLS_TARGET_LDFLAGS
  "--sysroot=${STAGE_TOOLS_SYSROOT} -L${STAGE_TOOLS_OUT_DIR}/usr/lib -L${STAGE_TOOLS_OUT_DIR}/usr/lib64 -L${STAGE_TOOLS_SYSROOT}/usr/lib -L${STAGE_TOOLS_SYSROOT}/lib -L${STAGE_TOOLS_DEPS_DIR}/usr/lib -L${STAGE_TOOLS_DEPS_DIR}/usr/lib64 -Wl,-rpath-link,${STAGE_TOOLS_OUT_DIR}/usr/lib -Wl,-rpath-link,${STAGE_TOOLS_OUT_DIR}/usr/lib64 -Wl,-rpath-link,${STAGE_TOOLS_SYSROOT}/usr/lib -Wl,-rpath-link,${STAGE_TOOLS_SYSROOT}/lib -Wl,-rpath-link,${STAGE_TOOLS_DEPS_DIR}/usr/lib -Wl,-rpath-link,${STAGE_TOOLS_DEPS_DIR}/usr/lib64")

foreach(required_path
    "${STAGE_TOOLS_SYSROOT}"
    "${STAGE_TOOLS_DEPS_DIR}/usr"
    "${STAGE_TOOLS_CC}"
    "${STAGE_TOOLS_AR}"
    "${STAGE_TOOLS_RANLIB}")
  if(NOT EXISTS "${required_path}")
    message(FATAL_ERROR "required path does not exist: ${required_path}")
  endif()
endforeach()

file(MAKE_DIRECTORY
  "${STAGE_TOOLS_CACHE_DIR}"
  "${STAGE_TOOLS_OUT_DIR}"
  "${CMAKE_BINARY_DIR}/src"
  "${CMAKE_BINARY_DIR}/build")

foreach(required_dependency
    "${STAGE_TOOLS_DEPS_DIR}/usr/include/readline/readline.h"
    "${STAGE_TOOLS_DEPS_DIR}/usr/include/readline/history.h"
    "${STAGE_TOOLS_DEPS_DIR}/usr/include/ncurses.h")
  if(NOT EXISTS "${required_dependency}")
    message(FATAL_ERROR "required bash dependency does not exist: ${required_dependency}")
  endif()
endforeach()

foreach(required_library readline history ncursesw)
  find_library(STAGE_TOOLS_${required_library}_LIBRARY
    NAMES "${required_library}"
    PATHS
      "${STAGE_TOOLS_DEPS_DIR}/usr/lib"
      "${STAGE_TOOLS_DEPS_DIR}/usr/lib64"
    NO_DEFAULT_PATH)
  if(NOT STAGE_TOOLS_${required_library}_LIBRARY)
    message(FATAL_ERROR "required bash dependency library was not found: ${required_library}")
  endif()
endforeach()

set(STAGE_TOOLS_COMMON_ENV
  "PATH=${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin:$ENV{PATH}"
  "CC=${STAGE_TOOLS_CC}"
  "CXX=${STAGE_TOOLS_CXX}"
  "LD=${STAGE_TOOLS_LD}"
  "AR=${STAGE_TOOLS_AR}"
  "RANLIB=${STAGE_TOOLS_RANLIB}"
  "STRIP=${STAGE_TOOLS_STRIP}"
  "NM=${STAGE_TOOLS_NM}"
  "CFLAGS=${STAGE_TOOLS_TARGET_CFLAGS}"
  "CXXFLAGS=${STAGE_TOOLS_TARGET_CFLAGS}"
  "LDFLAGS=${STAGE_TOOLS_TARGET_LDFLAGS}"
  "PKG_CONFIG_SYSROOT_DIR=${STAGE_TOOLS_DEPS_DIR}"
  "PKG_CONFIG_LIBDIR=${STAGE_TOOLS_OUT_DIR}/usr/lib/pkgconfig:${STAGE_TOOLS_OUT_DIR}/usr/lib64/pkgconfig:${STAGE_TOOLS_DEPS_DIR}/usr/lib/pkgconfig:${STAGE_TOOLS_DEPS_DIR}/usr/lib64/pkgconfig:${STAGE_TOOLS_SYSROOT}/usr/lib/pkgconfig:${STAGE_TOOLS_SYSROOT}/usr/share/pkgconfig")

set(STAGE_TOOLS_GIT_COMMON_ARGS
  prefix=/usr
  CC=${STAGE_TOOLS_CC}
  AR=${STAGE_TOOLS_AR}
  RANLIB=${STAGE_TOOLS_RANLIB}
  STRIP=${STAGE_TOOLS_STRIP}
  NO_GETTEXT=YesPlease
  NO_TCLTK=YesPlease
  CSPRNG_METHOD=
  USE_LIBPCRE2=YesPlease
  LIBPCREDIR=${STAGE_TOOLS_OUT_DIR}/usr
  CURLDIR=${STAGE_TOOLS_DEPS_DIR}/usr
  CURL_CONFIG=/bin/false
  CURL_LDFLAGS=-lcurl
  OPENSSLDIR=${STAGE_TOOLS_DEPS_DIR}/usr
  ZLIB_PATH=${STAGE_TOOLS_DEPS_DIR}/usr
  EXPATDIR=${STAGE_TOOLS_DEPS_DIR}/usr
  ICONVDIR=${STAGE_TOOLS_DEPS_DIR}/usr
  NEEDS_LIBICONV=YesPlease
  CFLAGS=${STAGE_TOOLS_GIT_CFLAGS}
  LDFLAGS=${STAGE_TOOLS_TARGET_LDFLAGS})

set(STAGE_TOOLS_BASH_BUILD_CCFLAGS
  "--sysroot=${STAGE_TOOLS_BUILD_SYSROOT} -O2 -D_GNU_SOURCE -D_DEFAULT_SOURCE -DCROSS_COMPILING -include ${STAGE_TOOLS_BUILD_SYSROOT}/usr/include/getopt.h -DHAVE_CONFIG_H -DSHELL -DPROGRAM='\"bash\"' -DCONF_HOSTTYPE='\"${STAGE_TOOLS_ARCH}\"' -DCONF_OSTYPE='\"linux-gnu\"' -DCONF_MACHTYPE='\"${STAGE_TOOLS_TARGET_TRIPLE}\"' -DCONF_VENDOR='\"unknown\"' -DLOCALEDIR='\"/usr/share/locale\"' -DPACKAGE='\"bash\"' -I${CMAKE_BINARY_DIR}/build/bash -I${CMAKE_BINARY_DIR}/build/bash/builtins -I${CMAKE_BINARY_DIR}/src/bash -I${CMAKE_BINARY_DIR}/src/bash/include -I${CMAKE_BINARY_DIR}/src/bash/lib -I${CMAKE_BINARY_DIR}/src/bash/builtins")
set(STAGE_TOOLS_BASH_BUILD_CFLAGS
  "--sysroot=${STAGE_TOOLS_BUILD_SYSROOT} -O2 -D_GNU_SOURCE -D_DEFAULT_SOURCE -include ${STAGE_TOOLS_BUILD_SYSROOT}/usr/include/getopt.h")

set(STAGE_TOOLS_BASH_ENV
  ${STAGE_TOOLS_COMMON_ENV}
  "BUILD_CC=${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/${STAGE_TOOLS_BUILD_TRIPLE}-clang"
  "CC_FOR_BUILD=${STAGE_TOOLS_BUILD_CC}"
  "CCFLAGS_FOR_BUILD=${STAGE_TOOLS_BASH_BUILD_CCFLAGS}"
  "CFLAGS_FOR_BUILD=${STAGE_TOOLS_BASH_BUILD_CFLAGS}"
  "LDFLAGS_FOR_BUILD=--sysroot=${STAGE_TOOLS_BUILD_SYSROOT}"
  "LIBS_FOR_BUILD="
  "CFLAGS=${STAGE_TOOLS_BASH_CFLAGS}"
  "CXXFLAGS=${STAGE_TOOLS_BASH_CFLAGS}"
  "CPPFLAGS=-I${STAGE_TOOLS_DEPS_DIR}/usr/include -I${STAGE_TOOLS_DEPS_DIR}/usr/include/ncursesw"
  "LIBS=-lreadline -lhistory -lncursesw"
  "ac_cv_rl_version=8.3")

ExternalProject_Add(stage-tools-pcre2
  URL "${STAGE_TOOLS_CACHE_DIR}/pcre2-10.47.tar.bz2"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  DOWNLOAD_DIR "${STAGE_TOOLS_CACHE_DIR}"
  SOURCE_DIR "${CMAKE_BINARY_DIR}/src/pcre2"
  BINARY_DIR "${CMAKE_BINARY_DIR}/build/pcre2"
  CONFIGURE_COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_COMMON_ENV}
      <SOURCE_DIR>/configure
        --build=${STAGE_TOOLS_BUILD_TRIPLE}
        --host=${STAGE_TOOLS_TARGET_TRIPLE}
        --prefix=/usr
        --enable-shared
        --disable-static
        --enable-pcre2-8
        --disable-pcre2-16
        --disable-pcre2-32
        --disable-jit
  BUILD_COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_COMMON_ENV}
      make -j${STAGE_TOOLS_JOBS}
  INSTALL_COMMAND
    /bin/sh
      "${CMAKE_CURRENT_LIST_DIR}/install_pcre2.sh"
      <SOURCE_DIR>
      <BINARY_DIR>
      ${STAGE_TOOLS_OUT_DIR}
  BUILD_IN_SOURCE 0
)

ExternalProject_Add(stage-tools-file
  SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}"
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    ${CMAKE_CURRENT_LIST_DIR}/build_file_package.sh
      --arch=${STAGE_TOOLS_ARCH}
      --jobs=${STAGE_TOOLS_JOBS}
      --cache-dir=${STAGE_TOOLS_CACHE_DIR}
      --out-dir=${STAGE_TOOLS_OUT_DIR}
      --deps-dir=${STAGE_TOOLS_DEPS_DIR}
  INSTALL_COMMAND ""
  BUILD_ALWAYS 1
)

ExternalProject_Add(stage-tools-git
  URL "${STAGE_TOOLS_CACHE_DIR}/git-2.54.0.tar.gz"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  DOWNLOAD_DIR "${STAGE_TOOLS_CACHE_DIR}"
  SOURCE_DIR "${CMAKE_BINARY_DIR}/src/git"
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_COMMON_ENV}
      make -j${STAGE_TOOLS_JOBS}
        ${STAGE_TOOLS_GIT_COMMON_ARGS}
  INSTALL_COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_COMMON_ENV}
      make install
        ${STAGE_TOOLS_GIT_COMMON_ARGS}
        DESTDIR=${STAGE_TOOLS_OUT_DIR}
  BUILD_IN_SOURCE 1
)

ExternalProject_Add(stage-tools-bash
  URL "${STAGE_TOOLS_CACHE_DIR}/bash-5.3.tar.gz"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  DOWNLOAD_DIR "${STAGE_TOOLS_CACHE_DIR}"
  SOURCE_DIR "${CMAKE_BINARY_DIR}/src/bash"
  BINARY_DIR "${CMAKE_BINARY_DIR}/build/bash"
  CONFIGURE_COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_BASH_ENV}
      <SOURCE_DIR>/configure
        --build=${STAGE_TOOLS_BUILD_TRIPLE}
        --host=${STAGE_TOOLS_TARGET_TRIPLE}
        --prefix=/usr
        --enable-readline
        --enable-history
        --with-installed-readline=${STAGE_TOOLS_DEPS_DIR}/usr
        --without-bash-malloc
        --disable-nls
  BUILD_COMMAND
    ${CMAKE_COMMAND} -E make_directory <BINARY_DIR>/builtins
  COMMAND
    ${CMAKE_COMMAND} -E copy_if_different
      <SOURCE_DIR>/builtins/getopt.h
      <BINARY_DIR>/builtins/getopt.h
  COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_BASH_ENV}
      make -j${STAGE_TOOLS_JOBS}
        CC_FOR_BUILD=${STAGE_TOOLS_BUILD_CC}
        "CCFLAGS_FOR_BUILD=${STAGE_TOOLS_BASH_BUILD_CCFLAGS}"
        "CFLAGS_FOR_BUILD=${STAGE_TOOLS_BASH_BUILD_CFLAGS}"
        LDFLAGS_FOR_BUILD=--sysroot=${STAGE_TOOLS_BUILD_SYSROOT}
        LIBS_FOR_BUILD=
  INSTALL_COMMAND
    ${CMAKE_COMMAND} -E env ${STAGE_TOOLS_BASH_ENV}
      make install DESTDIR=${STAGE_TOOLS_OUT_DIR}
)

ExternalProject_Add(stage-tools-meson
  URL "${STAGE_TOOLS_CACHE_DIR}/meson-1.11.1.tar.gz"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  DOWNLOAD_DIR "${STAGE_TOOLS_CACHE_DIR}"
  SOURCE_DIR "${CMAKE_BINARY_DIR}/src/meson"
  BINARY_DIR "${CMAKE_BINARY_DIR}/build/meson"
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND
    /bin/sh
      "${CMAKE_CURRENT_LIST_DIR}/install_meson_zipapp.sh"
      <SOURCE_DIR>
      <BINARY_DIR>
      ${STAGE_TOOLS_OUT_DIR}
  BUILD_IN_SOURCE 0
)

add_custom_target(stage-tools-bash-verify ALL
  COMMAND
    /bin/sh
      "${CMAKE_CURRENT_LIST_DIR}/verify_bash_deps.sh"
      "${STAGE_TOOLS_TOOLCHAIN_ROOT}/bin/llvm-readelf"
      "${STAGE_TOOLS_OUT_DIR}/usr/bin/bash"
  DEPENDS stage-tools-bash
)

add_dependencies(stage-tools-git stage-tools-pcre2 stage-tools-file)
add_dependencies(stage-tools-bash stage-tools-file)
add_dependencies(stage-tools-meson stage-tools-bash)
