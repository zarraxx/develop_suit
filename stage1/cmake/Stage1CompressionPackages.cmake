include_guard(GLOBAL)

include(CMakeParseArguments)

set(STAGE1_ZLIB_ARCHIVE "" CACHE FILEPATH "Path to the zlib source archive")
set(STAGE1_ZSTD_ARCHIVE "" CACHE FILEPATH "Path to the zstd source archive")
set(STAGE1_LZ4_ARCHIVE "" CACHE FILEPATH "Path to the lz4 source archive")
set(STAGE1_BZIP2_ARCHIVE "" CACHE FILEPATH "Path to the bzip2 source archive")
set(STAGE1_XZ_ARCHIVE "" CACHE FILEPATH "Path to the xz source archive")

set(STAGE1_ZLIB_SOURCE_DIR "" CACHE PATH "Direct path to the zlib source tree")
set(STAGE1_ZSTD_SOURCE_DIR "" CACHE PATH "Direct path to the zstd source tree")
set(STAGE1_LZ4_SOURCE_DIR "" CACHE PATH "Direct path to the lz4 source tree")
set(STAGE1_BZIP2_SOURCE_DIR "" CACHE PATH "Direct path to the bzip2 source tree")
set(STAGE1_XZ_SOURCE_DIR "" CACHE PATH "Direct path to the xz source tree")

set(STAGE1_ZLIB_URL
  "https://zlib.net/zlib-1.3.2.tar.gz"
  CACHE STRING
  "Download URL for zlib")
set(STAGE1_ZSTD_URL
  "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz"
  CACHE STRING
  "Download URL for zstd")
set(STAGE1_LZ4_URL
  "https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz"
  CACHE STRING
  "Download URL for lz4")
set(STAGE1_BZIP2_URL
  "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"
  CACHE STRING
  "Download URL for bzip2")
set(STAGE1_XZ_URL
  "https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.xz"
  CACHE STRING
  "Download URL for xz")

option(STAGE1_ENABLE_COMPRESSION_PACKAGES "Build compression libraries in stage1" ON)
option(STAGE1_ENABLE_ZLIB "Build zlib in stage1" ON)
option(STAGE1_ENABLE_ZSTD "Build zstd in stage1" ON)
option(STAGE1_ENABLE_LZ4 "Build lz4 in stage1" ON)
option(STAGE1_ENABLE_BZIP2 "Build bzip2 in stage1" ON)
option(STAGE1_ENABLE_XZ "Build xz/liblzma in stage1" ON)

set(STAGE1_COMPRESSION_PACKAGE_NAMES
  zlib
  zstd
  lz4
  bzip2
  xz)

function(stage1_add_cmake_package target_name)
  set(options)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX)
  set(multiValueArgs CMAKE_ARGS DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage1_add_cmake_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}")
  endif()

  set(_stage1_package_build_dir "${STAGE1_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  set(_stage1_stamp_file "${STAGE1_ROOTFS_DIR}/.${PKG_PACKAGE_NAME}-installed")

  add_custom_command(
    OUTPUT "${_stage1_stamp_file}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage1_package_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage1_package_build_dir}"
    COMMAND "${CMAKE_COMMAND}"
      ${STAGE1_NESTED_CMAKE_GENERATOR_ARGS}
      -S "${PKG_SOURCE_DIR}"
      -B "${_stage1_package_build_dir}"
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_SYSTEM_NAME=Linux
      -DCMAKE_SYSTEM_PROCESSOR=${STAGE1_TARGET_ARCH}
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
      -DCMAKE_INSTALL_PREFIX=${PKG_INSTALL_PREFIX}
      -DCMAKE_C_COMPILER=${STAGE1_TARGET_CC_WRAPPER}
      -DCMAKE_CXX_COMPILER=${STAGE1_TARGET_CXX_WRAPPER}
      -DCMAKE_AR=${STAGE1_LLVM_BIN_DIR}/llvm-ar
      -DCMAKE_NM=${STAGE1_LLVM_BIN_DIR}/llvm-nm
      -DCMAKE_OBJCOPY=${STAGE1_LLVM_BIN_DIR}/llvm-objcopy
      -DCMAKE_RANLIB=${STAGE1_LLVM_BIN_DIR}/llvm-ranlib
      -DCMAKE_STRIP=${STAGE1_LLVM_BIN_DIR}/llvm-strip
      -DCMAKE_SYSROOT=${STAGE1_ROOTFS_DIR}
      -DCMAKE_FIND_ROOT_PATH=${STAGE1_ROOTFS_DIR}
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
      ${PKG_CMAKE_ARGS}
    COMMAND "${CMAKE_COMMAND}" --build "${_stage1_package_build_dir}" --parallel "${STAGE1_JOBS}"
    COMMAND "${CMAKE_COMMAND}" -E env
      "DESTDIR=${STAGE1_ROOTFS_DIR}"
      "${CMAKE_COMMAND}" --install "${_stage1_package_build_dir}" --prefix "${PKG_INSTALL_PREFIX}" --strip
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
    DEPENDS ${PKG_DEPENDS}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE1_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage1_stamp_file}")
endfunction()

function(stage1_add_configure_make_package target_name)
  set(options BUILD_IN_SOURCE)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX CONFIGURE_PATH BUILD_TRIPLE HOST_TRIPLE)
  set(multiValueArgs CONFIGURE_ARGS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage1_add_configure_make_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}")
  endif()

  if(NOT DEFINED PKG_CONFIGURE_PATH OR "${PKG_CONFIGURE_PATH}" STREQUAL "")
    set(PKG_CONFIGURE_PATH "${PKG_SOURCE_DIR}/configure")
  endif()

  if(NOT DEFINED PKG_BUILD_TRIPLE OR "${PKG_BUILD_TRIPLE}" STREQUAL "")
    set(PKG_BUILD_TRIPLE "${STAGE1_BUILD_TRIPLE}")
  endif()

  if(NOT DEFINED PKG_HOST_TRIPLE OR "${PKG_HOST_TRIPLE}" STREQUAL "")
    set(PKG_HOST_TRIPLE "${STAGE1_TARGET_TRIPLE}")
  endif()

  if(PKG_BUILD_IN_SOURCE)
    set(_stage1_build_dir "${PKG_SOURCE_DIR}")
    set(_stage1_clean_build_dir_commands)
  else()
    set(_stage1_build_dir "${STAGE1_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
    set(_stage1_clean_build_dir_commands
      COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage1_build_dir}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage1_build_dir}")
  endif()

  set(_stage1_stamp_file "${STAGE1_ROOTFS_DIR}/.${PKG_PACKAGE_NAME}-installed")
  set(_stage1_env
    ${STAGE1_COMMON_TARGET_BUILD_ENV}
    "CONFIG_SHELL=/bin/sh"
    "SHELL=/bin/sh"
    ${PKG_ENV})

  add_custom_command(
    OUTPUT "${_stage1_stamp_file}"
    ${_stage1_clean_build_dir_commands}
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
      "-j${STAGE1_JOBS}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage1_env}
      "${STAGE1_MAKE_PROGRAM}"
      -C "${_stage1_build_dir}"
      "DESTDIR=${STAGE1_ROOTFS_DIR}"
      install
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
    DEPENDS ${PKG_DEPENDS}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE1_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage1_stamp_file}")
endfunction()

function(stage1_add_plain_make_package target_name)
  set(options)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX)
  set(multiValueArgs BUILD_ARGS BUILD_TARGETS INSTALL_ARGS INSTALL_COMMANDS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage1_add_plain_make_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}")
  endif()

  set(_stage1_build_dir "${STAGE1_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  set(_stage1_stage_prefix "${STAGE1_ROOTFS_DIR}${PKG_INSTALL_PREFIX}")
  set(_stage1_stamp_file "${STAGE1_ROOTFS_DIR}/.${PKG_PACKAGE_NAME}-installed")
  set(_stage1_env
    ${STAGE1_COMMON_TARGET_BUILD_ENV}
    ${PKG_ENV})

  if(DEFINED PKG_INSTALL_COMMANDS AND NOT "${PKG_INSTALL_COMMANDS}" STREQUAL "")
    set(_stage1_install_commands ${PKG_INSTALL_COMMANDS})
  else()
    set(_stage1_install_commands
      COMMAND "${CMAKE_COMMAND}" -E env
        ${_stage1_env}
        "${STAGE1_MAKE_PROGRAM}"
        -C "${_stage1_build_dir}"
        "PREFIX=${_stage1_stage_prefix}"
        ${PKG_INSTALL_ARGS}
        install)
  endif()

  add_custom_command(
    OUTPUT "${_stage1_stamp_file}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage1_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${PKG_SOURCE_DIR}" "${_stage1_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage1_env}
      "${STAGE1_MAKE_PROGRAM}"
      -C "${_stage1_build_dir}"
      "-j${STAGE1_JOBS}"
      ${PKG_BUILD_ARGS}
      ${PKG_BUILD_TARGETS}
    ${_stage1_install_commands}
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
    DEPENDS ${PKG_DEPENDS}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE1_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage1_stamp_file}")
endfunction()

function(stage1_register_compression_packages out_targets_var sysroot_stage_dep)
  if(NOT STAGE1_ENABLE_COMPRESSION_PACKAGES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  find_program(STAGE1_MAKE_PROGRAM NAMES gmake make REQUIRED)

  stage1_resolve_archive_source(
    STAGE1_ZLIB_SOURCE_DIR
    "zlib"
    "${STAGE1_CACHE_DIR}"
    "${STAGE1_SOURCE_DIR}/zlib"
    "CMakeLists.txt"
    SOURCE_DIR "${STAGE1_ZLIB_SOURCE_DIR}"
    ARCHIVE "${STAGE1_ZLIB_ARCHIVE}"
    DEFAULT_ARCHIVE "zlib-1.3.2.tar.gz"
    URL "${STAGE1_ZLIB_URL}"
    GLOB_PATTERNS
      "${STAGE1_CACHE_DIR}/zlib-*.tar.gz")

  stage1_resolve_archive_source(
    STAGE1_ZSTD_SOURCE_DIR
    "zstd"
    "${STAGE1_CACHE_DIR}"
    "${STAGE1_SOURCE_DIR}/zstd"
    "build/cmake/CMakeLists.txt"
    SOURCE_DIR "${STAGE1_ZSTD_SOURCE_DIR}"
    ARCHIVE "${STAGE1_ZSTD_ARCHIVE}"
    DEFAULT_ARCHIVE "zstd-1.5.7.tar.gz"
    URL "${STAGE1_ZSTD_URL}"
    SOURCE_SUBDIR "build/cmake"
    GLOB_PATTERNS
      "${STAGE1_CACHE_DIR}/zstd-*.tar.gz")

  if(STAGE1_ENABLE_LZ4)
    stage1_resolve_archive_source(
      STAGE1_LZ4_SOURCE_DIR
      "lz4"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/lz4"
      "build/cmake/CMakeLists.txt"
      SOURCE_DIR "${STAGE1_LZ4_SOURCE_DIR}"
      ARCHIVE "${STAGE1_LZ4_ARCHIVE}"
      DEFAULT_ARCHIVE "lz4-1.10.0.tar.gz"
      URL "${STAGE1_LZ4_URL}"
      SOURCE_SUBDIR "build/cmake"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/lz4-*.tar.gz")
  endif()

  stage1_resolve_archive_source(
    STAGE1_BZIP2_SOURCE_DIR
    "bzip2"
    "${STAGE1_CACHE_DIR}"
    "${STAGE1_SOURCE_DIR}/bzip2"
    "Makefile"
    SOURCE_DIR "${STAGE1_BZIP2_SOURCE_DIR}"
    ARCHIVE "${STAGE1_BZIP2_ARCHIVE}"
    DEFAULT_ARCHIVE "bzip2-1.0.8.tar.gz"
    URL "${STAGE1_BZIP2_URL}"
    GLOB_PATTERNS
      "${STAGE1_CACHE_DIR}/bzip2-*.tar.gz")

  stage1_resolve_archive_source(
    STAGE1_XZ_SOURCE_DIR
    "xz"
    "${STAGE1_CACHE_DIR}"
    "${STAGE1_SOURCE_DIR}/xz"
    "configure"
    SOURCE_DIR "${STAGE1_XZ_SOURCE_DIR}"
    ARCHIVE "${STAGE1_XZ_ARCHIVE}"
    DEFAULT_ARCHIVE "xz-5.8.3.tar.xz"
    URL "${STAGE1_XZ_URL}"
    GLOB_PATTERNS
      "${STAGE1_CACHE_DIR}/xz-*.tar.xz"
      "${STAGE1_CACHE_DIR}/xz-*.tar.gz")

  set(_stage1_targets "")
  stage1_get_no_doc_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_no_doc_install_commands)
  stage1_get_lib_only_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_lib_only_install_commands)

  if(STAGE1_ENABLE_ZLIB)
    stage1_add_cmake_package(
      stage1-zlib
      PACKAGE_NAME "zlib"
      SOURCE_DIR "${STAGE1_ZLIB_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CMAKE_ARGS
        -DZLIB_BUILD_TESTING=OFF
        -DZLIB_BUILD_SHARED=ON
        -DZLIB_BUILD_STATIC=ON
        -DZLIB_INSTALL=ON
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-zlib)
  endif()

  if(STAGE1_ENABLE_ZSTD)
    stage1_add_cmake_package(
      stage1-zstd
      PACKAGE_NAME "zstd"
      SOURCE_DIR "${STAGE1_ZSTD_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CMAKE_ARGS
        -DZSTD_BUILD_PROGRAMS=OFF
        -DZSTD_BUILD_TESTS=OFF
        -DZSTD_BUILD_CONTRIB=OFF
        -DZSTD_MULTITHREAD_SUPPORT=OFF
        -DZSTD_LEGACY_SUPPORT=OFF
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-zstd)
  endif()

  if(STAGE1_ENABLE_LZ4)
    stage1_add_cmake_package(
      stage1-lz4
      PACKAGE_NAME "lz4"
      SOURCE_DIR "${STAGE1_LZ4_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CMAKE_ARGS
        -DLZ4_BUILD_CLI=OFF
        -DLZ4_BUILD_LEGACY_LZ4C=OFF
        -DBUILD_SHARED_LIBS=ON
        -DBUILD_STATIC_LIBS=ON
        -DBUILD_TESTING=OFF
      POST_INSTALL_COMMANDS
        ${_stage1_lib_only_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-lz4)
  endif()

  if(STAGE1_ENABLE_BZIP2)
    stage1_add_plain_make_package(
      stage1-bzip2
      PACKAGE_NAME "bzip2"
      SOURCE_DIR "${STAGE1_BZIP2_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      BUILD_ARGS
        "CC=${STAGE1_TARGET_CC_WRAPPER}"
        "AR=${STAGE1_LLVM_BIN_DIR}/llvm-ar"
        "RANLIB=${STAGE1_LLVM_BIN_DIR}/llvm-ranlib"
        "CFLAGS=-O2 -D_FILE_OFFSET_BITS=64"
        "LDFLAGS="
      BUILD_TARGETS
        libbz2.a
      INSTALL_COMMANDS
        COMMAND "${CMAKE_COMMAND}" -E make_directory
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/include"
        COMMAND "${CMAKE_COMMAND}" -E make_directory
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/lib"
        COMMAND "${CMAKE_COMMAND}" -E copy
          "${STAGE1_PACKAGE_BUILD_ROOT}/bzip2/bzlib.h"
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/include/bzlib.h"
        COMMAND "${CMAKE_COMMAND}" -E copy
          "${STAGE1_PACKAGE_BUILD_ROOT}/bzip2/libbz2.a"
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/lib/libbz2.a"
      POST_INSTALL_COMMANDS
        COMMAND "${CMAKE_COMMAND}" -E env
          ${STAGE1_COMMON_TARGET_BUILD_ENV}
          "${STAGE1_MAKE_PROGRAM}"
          -C "${STAGE1_PACKAGE_BUILD_ROOT}/bzip2"
          -f Makefile-libbz2_so
          "CC=${STAGE1_TARGET_CC_WRAPPER}"
          "CFLAGS=-fpic -fPIC -O2 -D_FILE_OFFSET_BITS=64"
        COMMAND "${CMAKE_COMMAND}" -E copy
          "${STAGE1_PACKAGE_BUILD_ROOT}/bzip2/libbz2.so.1.0.8"
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/lib/libbz2.so.1.0.8"
        COMMAND "${CMAKE_COMMAND}" -E create_symlink
          "libbz2.so.1.0.8"
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/lib/libbz2.so.1.0"
        COMMAND "${CMAKE_COMMAND}" -E create_symlink
          "libbz2.so.1.0.8"
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/lib/libbz2.so.1"
        COMMAND "${CMAKE_COMMAND}" -E create_symlink
          "libbz2.so.1.0.8"
          "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/lib/libbz2.so"
        ${_stage1_lib_only_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-bzip2)
  endif()

  if(STAGE1_ENABLE_XZ)
    stage1_add_configure_make_package(
      stage1-xz
      PACKAGE_NAME "xz"
      SOURCE_DIR "${STAGE1_XZ_SOURCE_DIR}"
      CONFIGURE_PATH "${STAGE1_XZ_SOURCE_DIR}/configure"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CONFIGURE_ARGS
        --disable-doc
        --disable-nls
        --disable-xz
        --disable-xzdec
        --disable-lzmadec
        --disable-lzmainfo
        --disable-scripts
        --enable-shared
        --enable-static
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-xz)
  endif()

  set(${out_targets_var} "${_stage1_targets}" PARENT_SCOPE)
endfunction()
