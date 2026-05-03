cmake_minimum_required(VERSION 3.24)

project(stage1_tools LANGUAGES NONE)

include(ProcessorCount)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1Helpers.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1Autotools.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1CompressionPackages.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1CryptoPackages.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1ScriptingPackages.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1TerminalPackages.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Stage1UtilityPackages.cmake)

set(STAGE1_CACHE_DIR "${CMAKE_CURRENT_LIST_DIR}/../cache" CACHE PATH "Directory containing downloaded archives")
set(STAGE1_WORK_DIR "${CMAKE_BINARY_DIR}/stage1-work" CACHE PATH "Working directory used by the stage1 build")
set(STAGE1_PREBUILD_DIR "${STAGE1_WORK_DIR}/prebuild" CACHE PATH "Extracted host toolchains")
set(STAGE1_SOURCE_DIR "${STAGE1_WORK_DIR}/src" CACHE PATH "Extracted third-party source trees")
set(STAGE1_TMP_DIR "${STAGE1_WORK_DIR}/tmp" CACHE PATH "Temporary directory used by build tools instead of /tmp")
set(STAGE1_OUTPUT_DIR "${CMAKE_BINARY_DIR}/out" CACHE PATH "Build output directory")

set(STAGE1_TARGET_TRIPLE "" CACHE STRING "Target triple for stage1 packages, for example aarch64-unknown-linux-gnu")
set(STAGE1_INPUT_ROOTFS_DIR "" CACHE PATH "Input sysroot/rootfs directory produced by stage0")
set(STAGE1_INSTALL_PREFIX "/usr" CACHE STRING "Install prefix inside the target rootfs")

set(STAGE1_LLVM_ARCHIVE "" CACHE FILEPATH "Path to the LLVM/Clang host toolchain archive")
set(STAGE1_CLANG_ROOT "" CACHE PATH "Pre-extracted clang root containing bin/clang")

option(STAGE1_DOWNLOAD_MISSING "Automatically download missing archives into STAGE1_CACHE_DIR during configure" ON)
set(STAGE1_LLVM_X86_64_URL "https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-x86_64.tar.gz" CACHE STRING "Download URL for the x86_64 host LLVM toolchain archive")
set(STAGE1_LLVM_AARCH64_URL "https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-aarch64.tar.gz" CACHE STRING "Download URL for the aarch64 host LLVM toolchain archive")

ProcessorCount(_stage1_default_jobs)
if(NOT _stage1_default_jobs)
  set(_stage1_default_jobs 1)
endif()
set(STAGE1_JOBS "${_stage1_default_jobs}" CACHE STRING "Parallel build job count passed to make")

if(STAGE1_TARGET_TRIPLE STREQUAL "")
  message(FATAL_ERROR "STAGE1_TARGET_TRIPLE is required.")
endif()

if(STAGE1_INPUT_ROOTFS_DIR STREQUAL "")
  message(FATAL_ERROR "STAGE1_INPUT_ROOTFS_DIR is required.")
endif()

if(NOT EXISTS "${STAGE1_INPUT_ROOTFS_DIR}/usr")
  message(FATAL_ERROR "Input rootfs does not look valid: ${STAGE1_INPUT_ROOTFS_DIR}")
endif()

if(STAGE1_CLANG_ROOT STREQUAL "")
  if(STAGE1_LLVM_ARCHIVE STREQUAL "")
    stage1_resolve_default_llvm_archive(STAGE1_LLVM_ARCHIVE "${STAGE1_CACHE_DIR}")
  endif()
  stage1_archive_stem("${STAGE1_LLVM_ARCHIVE}" _stage1_llvm_stem)
  set(_stage1_llvm_extract_dir "${STAGE1_PREBUILD_DIR}/llvm/${_stage1_llvm_stem}")
  stage1_extract_archive_once("${STAGE1_LLVM_ARCHIVE}" "${_stage1_llvm_extract_dir}")
  stage1_unwrap_single_subdir("${_stage1_llvm_extract_dir}" "bin/clang" STAGE1_CLANG_ROOT)
endif()

find_program(STAGE1_HOST_CC NAMES cc clang gcc REQUIRED)
find_program(STAGE1_HOST_CXX NAMES c++ clang++ g++ REQUIRED)
find_program(STAGE1_MAKE_PROGRAM NAMES gmake make REQUIRED)

set(STAGE1_LLVM_BIN_DIR "${STAGE1_CLANG_ROOT}/bin")
set(STAGE1_ROOTFS_DIR "${STAGE1_OUTPUT_DIR}/${STAGE1_TARGET_TRIPLE}/rootfs")
set(STAGE1_TOOLCHAIN_DIR "${CMAKE_BINARY_DIR}/toolchain/${STAGE1_TARGET_TRIPLE}")
set(STAGE1_PACKAGE_BUILD_ROOT "${CMAKE_BINARY_DIR}/packages/${STAGE1_TARGET_TRIPLE}")
set(STAGE1_TARGET_CC_WRAPPER "${STAGE1_TOOLCHAIN_DIR}/clang-target.sh")
set(STAGE1_TARGET_CXX_WRAPPER "${STAGE1_TOOLCHAIN_DIR}/clang++-target.sh")
set(STAGE1_TARGET_RUNTIME_LIBDIR "${STAGE1_ROOTFS_DIR}/usr/lib/${STAGE1_TARGET_TRIPLE}")
set(STAGE1_TARGET_CLANG_RESOURCE_DIR "${STAGE1_TOOLCHAIN_DIR}/clang-resource")
set(STAGE1_TARGET_CLANG_RESOURCE_INCLUDE_DIR "${STAGE1_TARGET_CLANG_RESOURCE_DIR}/include")
set(STAGE1_TARGET_CLANG_RESOURCE_LIB_DIR "${STAGE1_TARGET_CLANG_RESOURCE_DIR}/lib/${STAGE1_TARGET_TRIPLE}")

foreach(_stage1_required_tool IN ITEMS clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-ranlib llvm-strip)
  if(NOT EXISTS "${STAGE1_LLVM_BIN_DIR}/${_stage1_required_tool}")
    message(FATAL_ERROR "Required LLVM tool not found: ${STAGE1_LLVM_BIN_DIR}/${_stage1_required_tool}")
  endif()
endforeach()

stage1_default_host_triple(STAGE1_BUILD_TRIPLE)

set(STAGE1_TARGET_ARCH "${STAGE1_TARGET_TRIPLE}")
string(REGEX REPLACE "-.*$" "" STAGE1_TARGET_ARCH "${STAGE1_TARGET_ARCH}")

set(STAGE1_NESTED_CMAKE_GENERATOR_ARGS "")
if(CMAKE_GENERATOR)
  list(APPEND STAGE1_NESTED_CMAKE_GENERATOR_ARGS -G "${CMAKE_GENERATOR}")
endif()
if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "")
  list(APPEND STAGE1_NESTED_CMAKE_GENERATOR_ARGS -A "${CMAKE_GENERATOR_PLATFORM}")
endif()
if(NOT CMAKE_GENERATOR_TOOLSET STREQUAL "")
  list(APPEND STAGE1_NESTED_CMAKE_GENERATOR_ARGS -T "${CMAKE_GENERATOR_TOOLSET}")
endif()

execute_process(
  COMMAND "${STAGE1_LLVM_BIN_DIR}/clang" --print-resource-dir
  RESULT_VARIABLE _stage1_resource_dir_status
  OUTPUT_VARIABLE STAGE1_HOST_CLANG_RESOURCE_DIR
  ERROR_VARIABLE _stage1_resource_dir_error
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_STRIP_TRAILING_WHITESPACE)

if(NOT _stage1_resource_dir_status EQUAL 0 OR STAGE1_HOST_CLANG_RESOURCE_DIR STREQUAL "")
  message(FATAL_ERROR
    "Could not query host clang resource dir from ${STAGE1_LLVM_BIN_DIR}/clang.\n"
    "Error: ${_stage1_resource_dir_error}")
endif()

file(MAKE_DIRECTORY "${STAGE1_TOOLCHAIN_DIR}")
file(MAKE_DIRECTORY "${STAGE1_PACKAGE_BUILD_ROOT}")
file(MAKE_DIRECTORY "${STAGE1_TMP_DIR}")
file(MAKE_DIRECTORY "${STAGE1_TARGET_CLANG_RESOURCE_DIR}/lib")
file(REMOVE_RECURSE "${STAGE1_TARGET_CLANG_RESOURCE_INCLUDE_DIR}")
file(REMOVE_RECURSE "${STAGE1_TARGET_CLANG_RESOURCE_LIB_DIR}")
file(CREATE_LINK
  "${STAGE1_HOST_CLANG_RESOURCE_DIR}/include"
  "${STAGE1_TARGET_CLANG_RESOURCE_INCLUDE_DIR}"
  SYMBOLIC)
file(CREATE_LINK
  "${STAGE1_TARGET_RUNTIME_LIBDIR}"
  "${STAGE1_TARGET_CLANG_RESOURCE_LIB_DIR}"
  SYMBOLIC)

set(STAGE1_CLANG_EXECUTABLE "${STAGE1_LLVM_BIN_DIR}/clang")
string(CONCAT STAGE1_TARGET_WRAPPER_ALWAYS_ARGS
  "\"-resource-dir=${STAGE1_TARGET_CLANG_RESOURCE_DIR}\" ")
string(CONCAT STAGE1_TARGET_WRAPPER_LINK_ARGS
  "\"--rtlib=compiler-rt\" "
  "\"--unwindlib=libunwind\" "
  "\"-L${STAGE1_TARGET_RUNTIME_LIBDIR}\"")
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/cmake/clang-target.sh.in"
  "${STAGE1_TARGET_CC_WRAPPER}"
  @ONLY)

set(STAGE1_CLANG_EXECUTABLE "${STAGE1_LLVM_BIN_DIR}/clang++")
string(CONCAT STAGE1_TARGET_WRAPPER_ALWAYS_ARGS
  "\"-stdlib=libc++\" "
  "\"-resource-dir=${STAGE1_TARGET_CLANG_RESOURCE_DIR}\" "
  "\"-nostdinc++\" "
  "\"-isystem${STAGE1_ROOTFS_DIR}/usr/include/c++/v1\" "
  "\"-isystem${STAGE1_ROOTFS_DIR}/usr/include/${STAGE1_TARGET_TRIPLE}/c++/v1\" ")
string(CONCAT STAGE1_TARGET_WRAPPER_LINK_ARGS
  "\"--rtlib=compiler-rt\" "
  "\"--unwindlib=libunwind\" "
  "\"-L${STAGE1_TARGET_RUNTIME_LIBDIR}\"")
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/cmake/clang-target.sh.in"
  "${STAGE1_TARGET_CXX_WRAPPER}"
  @ONLY)

file(CHMOD
  "${STAGE1_TARGET_CC_WRAPPER}"
  "${STAGE1_TARGET_CXX_WRAPPER}"
  PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE
    GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)

set(STAGE1_COMMON_TARGET_BUILD_ENV
  "TMPDIR=${STAGE1_TMP_DIR}"
  "TMP=${STAGE1_TMP_DIR}"
  "TEMP=${STAGE1_TMP_DIR}"
  "TEMPDIR=${STAGE1_TMP_DIR}"
  "PATH=${STAGE1_LLVM_BIN_DIR}:$ENV{PATH}"
  "CC=${STAGE1_TARGET_CC_WRAPPER}"
  "CXX=${STAGE1_TARGET_CXX_WRAPPER}"
  "AR=${STAGE1_LLVM_BIN_DIR}/llvm-ar"
  "NM=${STAGE1_LLVM_BIN_DIR}/llvm-nm"
  "OBJCOPY=${STAGE1_LLVM_BIN_DIR}/llvm-objcopy"
  "RANLIB=${STAGE1_LLVM_BIN_DIR}/llvm-ranlib"
  "STRIP=${STAGE1_LLVM_BIN_DIR}/llvm-strip"
  "CC_FOR_BUILD=${STAGE1_HOST_CC}"
  "CXX_FOR_BUILD=${STAGE1_HOST_CXX}"
  "CPP_FOR_BUILD=${STAGE1_HOST_CC} -E")

set(_stage1_sysroot_stage_stamp "${STAGE1_ROOTFS_DIR}/.sysroot-staged")
add_custom_command(
  OUTPUT "${_stage1_sysroot_stage_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${STAGE1_ROOTFS_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE1_ROOTFS_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${STAGE1_INPUT_ROOTFS_DIR}" "${STAGE1_ROOTFS_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE1_ROOTFS_DIR}/root"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_sysroot_stage_stamp}"
  DEPENDS "${STAGE1_INPUT_ROOTFS_DIR}/usr"
  COMMENT "Staging stage0 rootfs into ${STAGE1_ROOTFS_DIR}"
  VERBATIM)

add_custom_target(stage1-sysroot-staged
  DEPENDS "${_stage1_sysroot_stage_stamp}")

set(_stage1_rootfs_deps stage1-sysroot-staged)

if(COMMAND stage1_register_autotools_packages)
  stage1_register_autotools_packages(_stage1_autotools_targets stage1-sysroot-staged)
  if(_stage1_autotools_targets)
    list(APPEND _stage1_rootfs_deps ${_stage1_autotools_targets})
  endif()
endif()

if(COMMAND stage1_register_compression_packages)
  stage1_register_compression_packages(_stage1_compression_targets stage1-sysroot-staged)
  if(_stage1_compression_targets)
    list(APPEND _stage1_rootfs_deps ${_stage1_compression_targets})
  endif()
endif()

if(COMMAND stage1_register_crypto_packages)
  stage1_register_crypto_packages(_stage1_crypto_targets stage1-sysroot-staged)
  if(_stage1_crypto_targets)
    list(APPEND _stage1_rootfs_deps ${_stage1_crypto_targets})
  endif()
endif()

if(COMMAND stage1_register_scripting_packages)
  stage1_register_scripting_packages(_stage1_scripting_targets stage1-sysroot-staged)
  if(_stage1_scripting_targets)
    list(APPEND _stage1_rootfs_deps ${_stage1_scripting_targets})
  endif()
endif()

if(COMMAND stage1_register_terminal_packages)
  stage1_register_terminal_packages(_stage1_terminal_targets stage1-sysroot-staged)
  if(_stage1_terminal_targets)
    list(APPEND _stage1_rootfs_deps ${_stage1_terminal_targets})
  endif()
endif()

if(COMMAND stage1_register_utility_packages)
  stage1_register_utility_packages(_stage1_utility_targets stage1-sysroot-staged)
  if(_stage1_utility_targets)
    list(APPEND _stage1_rootfs_deps ${_stage1_utility_targets})
  endif()
endif()

add_custom_target(stage1-rootfs ALL
  DEPENDS ${_stage1_rootfs_deps})

message(STATUS "stage1 target triple   : ${STAGE1_TARGET_TRIPLE}")
message(STATUS "stage1 build triple    : ${STAGE1_BUILD_TRIPLE}")
message(STATUS "stage1 clang root      : ${STAGE1_CLANG_ROOT}")
message(STATUS "stage1 llvm archive    : ${STAGE1_LLVM_ARCHIVE}")
message(STATUS "stage1 input rootfs    : ${STAGE1_INPUT_ROOTFS_DIR}")
message(STATUS "stage1 output rootfs   : ${STAGE1_ROOTFS_DIR}")
message(STATUS "stage1 install prefix  : ${STAGE1_INSTALL_PREFIX}")
message(STATUS "stage1 runtime lib dir : ${STAGE1_TARGET_RUNTIME_LIBDIR}")
message(STATUS "stage1 resource dir    : ${STAGE1_TARGET_CLANG_RESOURCE_DIR}")
if(COMMAND stage1_register_autotools_packages)
  message(STATUS "stage1 make source     : ${STAGE1_MAKE_SOURCE_DIR}")
  message(STATUS "stage1 m4 source       : ${STAGE1_M4_SOURCE_DIR}")
  message(STATUS "stage1 autoconf source : ${STAGE1_AUTOCONF_SOURCE_DIR}")
  message(STATUS "stage1 automake source : ${STAGE1_AUTOMAKE_SOURCE_DIR}")
  message(STATUS "stage1 libtool source  : ${STAGE1_LIBTOOL_SOURCE_DIR}")
  message(STATUS "stage1 pkgconf source  : ${STAGE1_PKGCONF_SOURCE_DIR}")
else()
  message(STATUS "stage1 autotools       : disabled")
endif()
if(COMMAND stage1_register_utility_packages)
  message(STATUS "stage1 patchelf source : ${STAGE1_PATCHELF_SOURCE_DIR}")
  message(STATUS "stage1 curl source     : ${STAGE1_CURL_SOURCE_DIR}")
endif()
