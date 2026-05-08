include_guard(GLOBAL)

include(CMakeParseArguments)

set(STAGE1_MAKE_ARCHIVE "" CACHE FILEPATH "Path to the GNU make source archive")
set(STAGE1_M4_ARCHIVE "" CACHE FILEPATH "Path to the GNU m4 source archive")
set(STAGE1_AUTOCONF_ARCHIVE "" CACHE FILEPATH "Path to the autoconf source archive")
set(STAGE1_AUTOMAKE_ARCHIVE "" CACHE FILEPATH "Path to the automake source archive")
set(STAGE1_LIBTOOL_ARCHIVE "" CACHE FILEPATH "Path to the GNU libtool source archive")
set(STAGE1_PKGCONF_ARCHIVE "" CACHE FILEPATH "Path to the pkgconf source archive")

set(STAGE1_MAKE_SOURCE_DIR "" CACHE PATH "Direct path to the GNU make source tree")
set(STAGE1_M4_SOURCE_DIR "" CACHE PATH "Direct path to the GNU m4 source tree")
set(STAGE1_AUTOCONF_SOURCE_DIR "" CACHE PATH "Direct path to the autoconf source tree")
set(STAGE1_AUTOMAKE_SOURCE_DIR "" CACHE PATH "Direct path to the automake source tree")
set(STAGE1_LIBTOOL_SOURCE_DIR "" CACHE PATH "Direct path to the GNU libtool source tree")
set(STAGE1_PKGCONF_SOURCE_DIR "" CACHE PATH "Direct path to the pkgconf source tree")

set(STAGE1_MAKE_URL
  "https://ftp.gnu.org/gnu/make/make-4.3.tar.gz"
  CACHE STRING
  "Download URL for GNU make")
set(STAGE1_M4_URL
  "https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.xz"
  CACHE STRING
  "Download URL for GNU m4")
set(STAGE1_AUTOCONF_URL
  "https://ftp.gnu.org/gnu/autoconf/autoconf-2.73.tar.xz"
  CACHE STRING
  "Download URL for GNU autoconf")
set(STAGE1_AUTOMAKE_URL
  "https://ftp.gnu.org/gnu/automake/automake-1.18.tar.xz"
  CACHE STRING
  "Download URL for GNU automake")
set(STAGE1_LIBTOOL_URL
  "https://ftpmirror.gnu.org/libtool/libtool-2.5.4.tar.gz"
  CACHE STRING
  "Download URL for GNU libtool")
set(STAGE1_PKGCONF_URL
  "https://distfiles.ariadne.space/pkgconf/pkgconf-2.5.1.tar.xz"
  CACHE STRING
  "Download URL for pkgconf")

option(STAGE1_ENABLE_AUTOTOOLS_PACKAGES "Build autotools-related packages in stage1" ON)
option(STAGE1_ENABLE_MAKE "Build GNU make in stage1" ON)
option(STAGE1_ENABLE_M4 "Build GNU m4 in stage1" ON)
option(STAGE1_ENABLE_AUTOCONF "Build GNU autoconf in stage1" ON)
option(STAGE1_ENABLE_AUTOMAKE "Build GNU automake in stage1" ON)
option(STAGE1_ENABLE_LIBTOOL "Build GNU libtool in stage1" ON)
option(STAGE1_ENABLE_PKG_CONFIG "Build pkg-config in stage1" ON)

function(stage1_add_autotools_package target_name)
  set(options BUILD_IN_SOURCE)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX CONFIGURE_PATH BUILD_TRIPLE HOST_TRIPLE)
  set(multiValueArgs CONFIGURE_ARGS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage1_add_autotools_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}")
  endif()

  if(NOT DEFINED PKG_CONFIGURE_PATH OR "${PKG_CONFIGURE_PATH}" STREQUAL "")
    set(PKG_CONFIGURE_PATH "${PKG_SOURCE_DIR}/configure")
  endif()

  if(NOT EXISTS "${PKG_CONFIGURE_PATH}")
    message(FATAL_ERROR
      "Configure script for ${PKG_PACKAGE_NAME} does not exist: ${PKG_CONFIGURE_PATH}")
  endif()

  if(NOT DEFINED PKG_BUILD_TRIPLE OR "${PKG_BUILD_TRIPLE}" STREQUAL "")
    set(PKG_BUILD_TRIPLE "${STAGE1_BUILD_TRIPLE}")
  endif()

  if(NOT DEFINED PKG_HOST_TRIPLE OR "${PKG_HOST_TRIPLE}" STREQUAL "")
    set(PKG_HOST_TRIPLE "${STAGE1_TARGET_TRIPLE}")
  endif()

  if(PKG_BUILD_IN_SOURCE)
    set(_stage1_build_dir "${PKG_SOURCE_DIR}")
  else()
    set(_stage1_build_dir "${STAGE1_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  endif()

  set(_stage1_stamp_file "${STAGE1_ROOTFS_DIR}/.${PKG_PACKAGE_NAME}-installed")
  set(_stage1_parallel_args "")
  if(STAGE1_JOBS)
    list(APPEND _stage1_parallel_args "-j${STAGE1_JOBS}")
  endif()

  set(_stage1_env
    ${STAGE1_COMMON_AUTOTOOLS_ENV}
    ${PKG_ENV})

  set(_stage1_depends ${PKG_DEPENDS} "${PKG_CONFIGURE_PATH}")

  set(_stage1_clean_build_dir_commands)
  if(NOT PKG_BUILD_IN_SOURCE)
    list(APPEND _stage1_clean_build_dir_commands
      COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage1_build_dir}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage1_build_dir}")
  endif()

  stage1_collect_triplet_refresh_commands("${PKG_SOURCE_DIR}" _stage1_triplet_refresh_commands)

  add_custom_command(
    OUTPUT "${_stage1_stamp_file}"
    ${_stage1_clean_build_dir_commands}
    ${_stage1_triplet_refresh_commands}
    COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage1_build_dir}"
      "${CMAKE_COMMAND}" -E env
      ${_stage1_env}
      "${PKG_CONFIGURE_PATH}"
      "--host=${PKG_HOST_TRIPLE}"
      "--build=${PKG_BUILD_TRIPLE}"
      "--prefix=${PKG_INSTALL_PREFIX}"
      ${PKG_CONFIGURE_ARGS}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage1_env}
      "${STAGE1_MAKE_PROGRAM}"
      -C "${_stage1_build_dir}"
      ${_stage1_parallel_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage1_env}
      "${STAGE1_MAKE_PROGRAM}"
      -C "${_stage1_build_dir}"
      "DESTDIR=${STAGE1_ROOTFS_DIR}"
      install
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
    DEPENDS ${_stage1_depends}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE1_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage1_stamp_file}")
endfunction()

function(stage1_register_autotools_packages out_targets_var sysroot_stage_dep)
  if(NOT STAGE1_ENABLE_AUTOTOOLS_PACKAGES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  set(_stage1_any_enabled FALSE)
  foreach(_stage1_opt IN ITEMS
      STAGE1_ENABLE_MAKE
      STAGE1_ENABLE_M4
      STAGE1_ENABLE_AUTOCONF
      STAGE1_ENABLE_AUTOMAKE
      STAGE1_ENABLE_LIBTOOL
      STAGE1_ENABLE_PKG_CONFIG)
    if(${_stage1_opt})
      set(_stage1_any_enabled TRUE)
      break()
    endif()
  endforeach()

  if(NOT _stage1_any_enabled)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  find_program(STAGE1_MAKE_PROGRAM NAMES gmake make REQUIRED)
  find_program(STAGE1_HOST_PERL NAMES perl REQUIRED)
  find_program(STAGE1_HOST_M4 NAMES gm4 m4)
  unset(STAGE1_HOST_AUTOCONF)
  unset(STAGE1_HOST_AUTOHEADER)
  unset(STAGE1_HOST_AUTOM4TE)

  if(STAGE1_ENABLE_AUTOMAKE)
    find_program(STAGE1_HOST_AUTOCONF NAMES autoconf)
    if(NOT STAGE1_HOST_AUTOCONF)
      message(FATAL_ERROR
        "Building target automake still requires a host autoconf executable, but none was found in PATH.\n"
        "Run ./stages/stage1/prepare.sh or install host autoconf manually.")
    endif()
    find_program(STAGE1_HOST_AUTOHEADER NAMES autoheader)
    find_program(STAGE1_HOST_AUTOM4TE NAMES autom4te)
  endif()

  find_file(STAGE1_HOST_CONFIG_SUB
    NAMES config.sub
    PATHS
      /usr/share/misc
      /usr/share/automake-1.18
      /usr/share/automake-1.17
      /usr/share/automake-1.16
    NO_DEFAULT_PATH)
  find_file(STAGE1_HOST_CONFIG_GUESS
    NAMES config.guess
    PATHS
      /usr/share/misc
      /usr/share/automake-1.18
      /usr/share/automake-1.17
      /usr/share/automake-1.16
    NO_DEFAULT_PATH)

  set(STAGE1_COMMON_AUTOTOOLS_ENV
    "TMPDIR=${STAGE1_TMP_DIR}"
    "TMP=${STAGE1_TMP_DIR}"
    "TEMP=${STAGE1_TMP_DIR}"
    "TEMPDIR=${STAGE1_TMP_DIR}"
    "PATH=${STAGE1_LLVM_BIN_DIR}:$ENV{PATH}"
    "CONFIG_SHELL=/bin/sh"
    "SHELL=/bin/sh"
    "CC=${STAGE1_TARGET_CC_WRAPPER}"
    "CXX=${STAGE1_TARGET_CXX_WRAPPER}"
    "AR=${STAGE1_LLVM_BIN_DIR}/llvm-ar"
    "NM=${STAGE1_LLVM_BIN_DIR}/llvm-nm"
    "OBJCOPY=${STAGE1_LLVM_BIN_DIR}/llvm-objcopy"
    "RANLIB=${STAGE1_LLVM_BIN_DIR}/llvm-ranlib"
    "STRIP=${STAGE1_LLVM_BIN_DIR}/llvm-strip"
    "CC_FOR_BUILD=${STAGE1_HOST_CC}"
    "CXX_FOR_BUILD=${STAGE1_HOST_CXX}"
    "CPP_FOR_BUILD=${STAGE1_HOST_CC} -E"
    "PERL=${STAGE1_HOST_PERL}"
    "MAKEINFO=true"
    "HELP2MAN=true")

  if(STAGE1_HOST_M4)
    list(APPEND STAGE1_COMMON_AUTOTOOLS_ENV "M4=${STAGE1_HOST_M4}")
  else()
    message(WARNING
      "Host m4 was not found. Building autoconf/automake/libtool will likely fail until you "
      "install m4 or pass -DSTAGE1_HOST_M4=/path/to/m4.")
  endif()

  if(STAGE1_ENABLE_MAKE)
    stage1_resolve_archive_source(
      STAGE1_MAKE_SOURCE_DIR
      "GNU make"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/make"
      "configure"
      SOURCE_DIR "${STAGE1_MAKE_SOURCE_DIR}"
      ARCHIVE "${STAGE1_MAKE_ARCHIVE}"
      DEFAULT_ARCHIVE "make-4.3.tar.gz"
      URL "${STAGE1_MAKE_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/make-*.tar.gz"
        "${STAGE1_CACHE_DIR}/make-*.tar.xz")
  endif()

  if(STAGE1_ENABLE_M4)
    stage1_resolve_archive_source(
      STAGE1_M4_SOURCE_DIR
      "GNU m4"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/m4"
      "configure"
      SOURCE_DIR "${STAGE1_M4_SOURCE_DIR}"
      ARCHIVE "${STAGE1_M4_ARCHIVE}"
      DEFAULT_ARCHIVE "m4-1.4.21.tar.xz"
      URL "${STAGE1_M4_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/m4-*.tar.xz"
        "${STAGE1_CACHE_DIR}/m4-*.tar.gz")
  endif()

  if(STAGE1_ENABLE_AUTOCONF)
    stage1_resolve_archive_source(
      STAGE1_AUTOCONF_SOURCE_DIR
      "GNU autoconf"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/autoconf"
      "configure"
      SOURCE_DIR "${STAGE1_AUTOCONF_SOURCE_DIR}"
      ARCHIVE "${STAGE1_AUTOCONF_ARCHIVE}"
      DEFAULT_ARCHIVE "autoconf-2.73.tar.xz"
      URL "${STAGE1_AUTOCONF_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/autoconf-*.tar.xz"
        "${STAGE1_CACHE_DIR}/autoconf-*.tar.gz")
  endif()

  if(STAGE1_ENABLE_AUTOMAKE)
    stage1_resolve_archive_source(
      STAGE1_AUTOMAKE_SOURCE_DIR
      "GNU automake"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/automake"
      "configure"
      SOURCE_DIR "${STAGE1_AUTOMAKE_SOURCE_DIR}"
      ARCHIVE "${STAGE1_AUTOMAKE_ARCHIVE}"
      DEFAULT_ARCHIVE "automake-1.18.tar.xz"
      URL "${STAGE1_AUTOMAKE_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/automake-*.tar.xz"
        "${STAGE1_CACHE_DIR}/automake-*.tar.gz")
  endif()

  if(STAGE1_ENABLE_LIBTOOL)
    stage1_resolve_archive_source(
      STAGE1_LIBTOOL_SOURCE_DIR
      "GNU libtool"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/libtool"
      "configure"
      SOURCE_DIR "${STAGE1_LIBTOOL_SOURCE_DIR}"
      ARCHIVE "${STAGE1_LIBTOOL_ARCHIVE}"
      DEFAULT_ARCHIVE "libtool-2.5.4.tar.gz"
      URL "${STAGE1_LIBTOOL_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/libtool-*.tar.gz"
        "${STAGE1_CACHE_DIR}/libtool-*.tar.xz")
  endif()

  if(STAGE1_ENABLE_PKG_CONFIG)
    stage1_resolve_archive_source(
      STAGE1_PKGCONF_SOURCE_DIR
      "pkgconf"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/pkgconf"
      "configure"
      SOURCE_DIR "${STAGE1_PKGCONF_SOURCE_DIR}"
      ARCHIVE "${STAGE1_PKGCONF_ARCHIVE}"
      DEFAULT_ARCHIVE "pkgconf-2.5.1.tar.xz"
      URL "${STAGE1_PKGCONF_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/pkgconf-*.tar.xz"
        "${STAGE1_CACHE_DIR}/pkgconf-*.tar.gz")
  endif()

  stage1_get_no_doc_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_no_doc_install_commands)

  set(_stage1_targets "")

  if(STAGE1_ENABLE_MAKE)
    stage1_add_autotools_package(
      stage1-make
      PACKAGE_NAME "gnu-make"
      SOURCE_DIR "${STAGE1_MAKE_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CONFIGURE_ARGS
        "--without-guile"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands})
    list(APPEND _stage1_targets stage1-make)
  endif()

  if(STAGE1_ENABLE_M4)
    stage1_add_autotools_package(
      stage1-m4
      PACKAGE_NAME "m4"
      SOURCE_DIR "${STAGE1_M4_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands})
    list(APPEND _stage1_targets stage1-m4)
  endif()

  if(STAGE1_ENABLE_AUTOCONF)
    set(_stage1_autoconf_deps "${sysroot_stage_dep}")
    if(TARGET stage1-m4)
      list(APPEND _stage1_autoconf_deps stage1-m4)
    endif()
    if(TARGET stage1-perl)
      list(APPEND _stage1_autoconf_deps stage1-perl)
    endif()

    stage1_add_autotools_package(
      stage1-autoconf
      PACKAGE_NAME "autoconf"
      SOURCE_DIR "${STAGE1_AUTOCONF_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      DEPENDS ${_stage1_autoconf_deps}
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands})
    list(APPEND _stage1_targets stage1-autoconf)
  endif()

  if(STAGE1_ENABLE_AUTOMAKE)
    set(_stage1_automake_deps "${sysroot_stage_dep}")
    set(_stage1_automake_env "")
    if(TARGET stage1-m4)
      list(APPEND _stage1_automake_deps stage1-m4)
    endif()
    if(TARGET stage1-autoconf)
      list(APPEND _stage1_automake_deps stage1-autoconf)
    endif()
    if(TARGET stage1-perl)
      list(APPEND _stage1_automake_deps stage1-perl)
    endif()
    if(STAGE1_HOST_AUTOCONF)
      list(APPEND _stage1_automake_env "AUTOCONF=${STAGE1_HOST_AUTOCONF}")
    endif()
    if(STAGE1_HOST_AUTOHEADER)
      list(APPEND _stage1_automake_env "AUTOHEADER=${STAGE1_HOST_AUTOHEADER}")
    endif()
    if(STAGE1_HOST_AUTOM4TE)
      list(APPEND _stage1_automake_env "AUTOM4TE=${STAGE1_HOST_AUTOM4TE}")
    endif()

    stage1_add_autotools_package(
      stage1-automake
      PACKAGE_NAME "automake"
      SOURCE_DIR "${STAGE1_AUTOMAKE_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      DEPENDS ${_stage1_automake_deps}
      ENV ${_stage1_automake_env}
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands})
    list(APPEND _stage1_targets stage1-automake)
  endif()

  if(STAGE1_ENABLE_LIBTOOL)
    set(_stage1_libtool_deps "${sysroot_stage_dep}")
    if(TARGET stage1-m4)
      list(APPEND _stage1_libtool_deps stage1-m4)
    endif()
    if(TARGET stage1-perl)
      list(APPEND _stage1_libtool_deps stage1-perl)
    endif()

    stage1_add_autotools_package(
      stage1-libtool
      PACKAGE_NAME "libtool"
      SOURCE_DIR "${STAGE1_LIBTOOL_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CONFIGURE_ARGS
        "--enable-ltdl-install"
      DEPENDS ${_stage1_libtool_deps}
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands})
    list(APPEND _stage1_targets stage1-libtool)
  endif()

  if(STAGE1_ENABLE_PKG_CONFIG)
    set(_stage1_pkgconf_prefix_root "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}")
    stage1_add_autotools_package(
      stage1-pkg-config
      PACKAGE_NAME "pkg-config"
      SOURCE_DIR "${STAGE1_PKGCONF_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CONFIGURE_ARGS
        "--with-pkg-config-dir=${STAGE1_INSTALL_PREFIX}/lib/pkgconfig:${STAGE1_INSTALL_PREFIX}/share/pkgconfig"
        "--with-system-libdir=${STAGE1_INSTALL_PREFIX}/lib"
        "--with-system-includedir=${STAGE1_INSTALL_PREFIX}/include"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands}
        COMMAND "${CMAKE_COMMAND}" -E rm -f "${_stage1_pkgconf_prefix_root}/bin/pkg-config"
        COMMAND "${CMAKE_COMMAND}" -E create_symlink "pkgconf" "${_stage1_pkgconf_prefix_root}/bin/pkg-config")
    list(APPEND _stage1_targets stage1-pkg-config)
  endif()

  set(STAGE1_MAKE_SOURCE_DIR "${STAGE1_MAKE_SOURCE_DIR}" PARENT_SCOPE)
  set(STAGE1_M4_SOURCE_DIR "${STAGE1_M4_SOURCE_DIR}" PARENT_SCOPE)
  set(STAGE1_AUTOCONF_SOURCE_DIR "${STAGE1_AUTOCONF_SOURCE_DIR}" PARENT_SCOPE)
  set(STAGE1_AUTOMAKE_SOURCE_DIR "${STAGE1_AUTOMAKE_SOURCE_DIR}" PARENT_SCOPE)
  set(STAGE1_LIBTOOL_SOURCE_DIR "${STAGE1_LIBTOOL_SOURCE_DIR}" PARENT_SCOPE)
  set(STAGE1_PKGCONF_SOURCE_DIR "${STAGE1_PKGCONF_SOURCE_DIR}" PARENT_SCOPE)
  set(${out_targets_var} "${_stage1_targets}" PARENT_SCOPE)
endfunction()
