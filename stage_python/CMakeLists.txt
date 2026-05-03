cmake_minimum_required(VERSION 3.24)

project(stage_python LANGUAGES NONE)

include(ProcessorCount)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonHelpers.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonTargetBuild.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonBuildToolPackages.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonPythonSupportPackages.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonInterpreterPackages.cmake)

set(STAGE_PYTHON_CACHE_DIR "${CMAKE_CURRENT_LIST_DIR}/../cache" CACHE PATH "Directory containing downloaded archives")
set(STAGE_PYTHON_WORK_DIR "${CMAKE_BINARY_DIR}/stage-python-work" CACHE PATH "Working directory used by the stage_python build")
set(STAGE_PYTHON_PREBUILD_DIR "${STAGE_PYTHON_WORK_DIR}/prebuild" CACHE PATH "Extracted host toolchains")
set(STAGE_PYTHON_SOURCE_DIR "${STAGE_PYTHON_WORK_DIR}/src" CACHE PATH "Extracted third-party source trees")
set(STAGE_PYTHON_TMP_DIR "${STAGE_PYTHON_WORK_DIR}/tmp" CACHE PATH "Temporary directory used by build tools instead of /tmp")
set(STAGE_PYTHON_OUTPUT_DIR "${CMAKE_BINARY_DIR}/out" CACHE PATH "Build output directory")

set(STAGE_PYTHON_TARGET_TRIPLE "" CACHE STRING "Target triple for stage_python packages, for example aarch64-unknown-linux-gnu")
set(STAGE_PYTHON_INPUT_ROOTFS_DIR "" CACHE PATH "Input rootfs directory produced by stage1")
set(STAGE_PYTHON_INSTALL_PREFIX "/usr" CACHE STRING "Install prefix inside the target rootfs")

set(STAGE_PYTHON_LLVM_ARCHIVE "" CACHE FILEPATH "Path to the LLVM/Clang host toolchain archive")
set(STAGE_PYTHON_CLANG_ROOT "" CACHE PATH "Pre-extracted clang root containing bin/clang")

option(STAGE_PYTHON_DOWNLOAD_MISSING "Automatically download missing archives into STAGE_PYTHON_CACHE_DIR during configure" ON)
set(STAGE_PYTHON_LLVM_X86_64_URL "https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-x86_64.tar.gz" CACHE STRING "Download URL for the x86_64 host LLVM toolchain archive")
set(STAGE_PYTHON_LLVM_AARCH64_URL "https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-aarch64.tar.gz" CACHE STRING "Download URL for the aarch64 host LLVM toolchain archive")

ProcessorCount(_stage_python_default_jobs)
if(NOT _stage_python_default_jobs)
  set(_stage_python_default_jobs 1)
endif()
set(STAGE_PYTHON_JOBS "${_stage_python_default_jobs}" CACHE STRING "Parallel build job count passed to make")

if(STAGE_PYTHON_TARGET_TRIPLE STREQUAL "")
  message(FATAL_ERROR "STAGE_PYTHON_TARGET_TRIPLE is required.")
endif()

if(STAGE_PYTHON_INPUT_ROOTFS_DIR STREQUAL "")
  message(FATAL_ERROR "STAGE_PYTHON_INPUT_ROOTFS_DIR is required.")
endif()

if(NOT EXISTS "${STAGE_PYTHON_INPUT_ROOTFS_DIR}/usr")
  message(FATAL_ERROR "Input rootfs does not look valid: ${STAGE_PYTHON_INPUT_ROOTFS_DIR}")
endif()

if(STAGE_PYTHON_CLANG_ROOT STREQUAL "")
  if(STAGE_PYTHON_LLVM_ARCHIVE STREQUAL "")
    stage_python_resolve_default_llvm_archive(STAGE_PYTHON_LLVM_ARCHIVE "${STAGE_PYTHON_CACHE_DIR}")
  endif()
  stage_python_archive_stem("${STAGE_PYTHON_LLVM_ARCHIVE}" _stage_python_llvm_stem)
  set(_stage_python_llvm_extract_dir "${STAGE_PYTHON_PREBUILD_DIR}/llvm/${_stage_python_llvm_stem}")
  stage_python_extract_archive_once("${STAGE_PYTHON_LLVM_ARCHIVE}" "${_stage_python_llvm_extract_dir}")
  stage_python_unwrap_single_subdir("${_stage_python_llvm_extract_dir}" "bin/clang" STAGE_PYTHON_CLANG_ROOT)
endif()

find_program(STAGE_PYTHON_HOST_CC NAMES cc clang gcc REQUIRED)
find_program(STAGE_PYTHON_HOST_CXX NAMES c++ clang++ g++ REQUIRED)
find_program(STAGE_PYTHON_MAKE_PROGRAM NAMES gmake make REQUIRED)
find_program(STAGE_PYTHON_CP_PROGRAM NAMES cp REQUIRED)
find_program(STAGE_PYTHON_HOST_PERL NAMES perl REQUIRED)
find_program(STAGE_PYTHON_HOST_M4 NAMES gm4 m4)

find_file(STAGE_PYTHON_HOST_CONFIG_SUB
  NAMES config.sub
  PATHS
    /usr/share/misc
    /usr/share/automake-1.18
    /usr/share/automake-1.17
    /usr/share/automake-1.16
  NO_DEFAULT_PATH)
find_file(STAGE_PYTHON_HOST_CONFIG_GUESS
  NAMES config.guess
  PATHS
    /usr/share/misc
    /usr/share/automake-1.18
    /usr/share/automake-1.17
    /usr/share/automake-1.16
  NO_DEFAULT_PATH)

set(STAGE_PYTHON_LLVM_BIN_DIR "${STAGE_PYTHON_CLANG_ROOT}/bin")
set(STAGE_PYTHON_ROOTFS_DIR "${STAGE_PYTHON_OUTPUT_DIR}/${STAGE_PYTHON_TARGET_TRIPLE}/rootfs")
set(STAGE_PYTHON_PREFIX_ROOT "${STAGE_PYTHON_ROOTFS_DIR}${STAGE_PYTHON_INSTALL_PREFIX}")
set(STAGE_PYTHON_TOOLCHAIN_DIR "${CMAKE_BINARY_DIR}/toolchain/${STAGE_PYTHON_TARGET_TRIPLE}")
set(STAGE_PYTHON_PACKAGE_BUILD_ROOT "${CMAKE_BINARY_DIR}/packages/${STAGE_PYTHON_TARGET_TRIPLE}")
set(STAGE_PYTHON_TARGET_CC_WRAPPER "${STAGE_PYTHON_TOOLCHAIN_DIR}/clang-target.sh")
set(STAGE_PYTHON_TARGET_CXX_WRAPPER "${STAGE_PYTHON_TOOLCHAIN_DIR}/clang++-target.sh")
set(STAGE_PYTHON_TARGET_RUNTIME_LIBDIR "${STAGE_PYTHON_ROOTFS_DIR}/usr/lib/${STAGE_PYTHON_TARGET_TRIPLE}")
set(STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR "${STAGE_PYTHON_TOOLCHAIN_DIR}/clang-resource")
set(STAGE_PYTHON_TARGET_CLANG_RESOURCE_INCLUDE_DIR "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}/include")
set(STAGE_PYTHON_TARGET_CLANG_RESOURCE_LIB_DIR "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}/lib/${STAGE_PYTHON_TARGET_TRIPLE}")
set(STAGE_PYTHON_TARGET_CLANG_RESOURCE_PROFILE_LIB_DIR "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}/lib/linux")

foreach(_stage_python_required_tool IN ITEMS clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-ranlib llvm-strip)
  if(NOT EXISTS "${STAGE_PYTHON_LLVM_BIN_DIR}/${_stage_python_required_tool}")
    message(FATAL_ERROR "Required LLVM tool not found: ${STAGE_PYTHON_LLVM_BIN_DIR}/${_stage_python_required_tool}")
  endif()
endforeach()

stage_python_default_host_triple(STAGE_PYTHON_BUILD_TRIPLE)

set(STAGE_PYTHON_TARGET_ARCH "${STAGE_PYTHON_TARGET_TRIPLE}")
string(REGEX REPLACE "-.*$" "" STAGE_PYTHON_TARGET_ARCH "${STAGE_PYTHON_TARGET_ARCH}")
set(STAGE_PYTHON_TARGET_CLANG_PROFILE_RUNTIME "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_PROFILE_LIB_DIR}/libclang_rt.profile-${STAGE_PYTHON_TARGET_ARCH}.a")

set(STAGE_PYTHON_NESTED_CMAKE_GENERATOR_ARGS "")
if(CMAKE_GENERATOR)
  list(APPEND STAGE_PYTHON_NESTED_CMAKE_GENERATOR_ARGS -G "${CMAKE_GENERATOR}")
endif()
if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "")
  list(APPEND STAGE_PYTHON_NESTED_CMAKE_GENERATOR_ARGS -A "${CMAKE_GENERATOR_PLATFORM}")
endif()
if(NOT CMAKE_GENERATOR_TOOLSET STREQUAL "")
  list(APPEND STAGE_PYTHON_NESTED_CMAKE_GENERATOR_ARGS -T "${CMAKE_GENERATOR_TOOLSET}")
endif()

execute_process(
  COMMAND "${STAGE_PYTHON_LLVM_BIN_DIR}/clang" --print-resource-dir
  RESULT_VARIABLE _stage_python_resource_dir_status
  OUTPUT_VARIABLE STAGE_PYTHON_HOST_CLANG_RESOURCE_DIR
  ERROR_VARIABLE _stage_python_resource_dir_error
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_STRIP_TRAILING_WHITESPACE)

if(NOT _stage_python_resource_dir_status EQUAL 0 OR STAGE_PYTHON_HOST_CLANG_RESOURCE_DIR STREQUAL "")
  message(FATAL_ERROR
    "Could not query host clang resource dir from ${STAGE_PYTHON_LLVM_BIN_DIR}/clang.\n"
    "Error: ${_stage_python_resource_dir_error}")
endif()

file(MAKE_DIRECTORY "${STAGE_PYTHON_TOOLCHAIN_DIR}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_TMP_DIR}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}/lib")
file(REMOVE_RECURSE "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_INCLUDE_DIR}")
file(REMOVE_RECURSE "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_LIB_DIR}")
file(REMOVE_RECURSE "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_PROFILE_LIB_DIR}")
file(CREATE_LINK
  "${STAGE_PYTHON_HOST_CLANG_RESOURCE_DIR}/include"
  "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_INCLUDE_DIR}"
  SYMBOLIC)
file(CREATE_LINK
  "${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}"
  "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_LIB_DIR}"
  SYMBOLIC)
file(MAKE_DIRECTORY "${STAGE_PYTHON_TARGET_CLANG_RESOURCE_PROFILE_LIB_DIR}")
if(EXISTS "${STAGE_PYTHON_HOST_CLANG_RESOURCE_DIR}/lib/${STAGE_PYTHON_BUILD_TRIPLE}/libclang_rt.profile.a")
  file(CREATE_LINK
    "${STAGE_PYTHON_HOST_CLANG_RESOURCE_DIR}/lib/${STAGE_PYTHON_BUILD_TRIPLE}/libclang_rt.profile.a"
    "${STAGE_PYTHON_TARGET_CLANG_PROFILE_RUNTIME}"
    SYMBOLIC)
endif()

set(STAGE_PYTHON_CLANG_EXECUTABLE "${STAGE_PYTHON_LLVM_BIN_DIR}/clang")
string(CONCAT STAGE_PYTHON_TARGET_WRAPPER_ALWAYS_ARGS
  "\"-resource-dir=${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}\" ")
string(CONCAT STAGE_PYTHON_TARGET_WRAPPER_LINK_ARGS
  "\"--rtlib=compiler-rt\" "
  "\"--unwindlib=libunwind\" "
  "\"-L${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}\"")
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/cmake/clang-target.sh.in"
  "${STAGE_PYTHON_TARGET_CC_WRAPPER}"
  @ONLY)

set(STAGE_PYTHON_CLANG_EXECUTABLE "${STAGE_PYTHON_LLVM_BIN_DIR}/clang++")
string(CONCAT STAGE_PYTHON_TARGET_WRAPPER_ALWAYS_ARGS
  "\"-stdlib=libc++\" "
  "\"-resource-dir=${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}\" "
  "\"-nostdinc++\" "
  "\"-isystem${STAGE_PYTHON_ROOTFS_DIR}/usr/include/c++/v1\" "
  "\"-isystem${STAGE_PYTHON_ROOTFS_DIR}/usr/include/${STAGE_PYTHON_TARGET_TRIPLE}/c++/v1\" ")
string(CONCAT STAGE_PYTHON_TARGET_WRAPPER_LINK_ARGS
  "\"--rtlib=compiler-rt\" "
  "\"--unwindlib=libunwind\" "
  "\"-L${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}\"")
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/cmake/clang-target.sh.in"
  "${STAGE_PYTHON_TARGET_CXX_WRAPPER}"
  @ONLY)

file(CHMOD
  "${STAGE_PYTHON_TARGET_CC_WRAPPER}"
  "${STAGE_PYTHON_TARGET_CXX_WRAPPER}"
  PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE
    GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)

set(STAGE_PYTHON_COMMON_TARGET_BUILD_ENV
  "TMPDIR=${STAGE_PYTHON_TMP_DIR}"
  "TMP=${STAGE_PYTHON_TMP_DIR}"
  "TEMP=${STAGE_PYTHON_TMP_DIR}"
  "TEMPDIR=${STAGE_PYTHON_TMP_DIR}"
  "PATH=${STAGE_PYTHON_LLVM_BIN_DIR}:$ENV{PATH}"
  "CC=${STAGE_PYTHON_TARGET_CC_WRAPPER}"
  "CXX=${STAGE_PYTHON_TARGET_CXX_WRAPPER}"
  "AR=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-ar"
  "NM=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-nm"
  "OBJCOPY=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-objcopy"
  "RANLIB=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-ranlib"
  "STRIP=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-strip"
  "CC_FOR_BUILD=${STAGE_PYTHON_HOST_CC}"
  "CXX_FOR_BUILD=${STAGE_PYTHON_HOST_CXX}"
  "CPP_FOR_BUILD=${STAGE_PYTHON_HOST_CC} -E")

set(STAGE_PYTHON_COMMON_AUTOTOOLS_ENV
  ${STAGE_PYTHON_COMMON_TARGET_BUILD_ENV}
  "CONFIG_SHELL=/bin/sh"
  "SHELL=/bin/sh"
  "CPPFLAGS=-D_GNU_SOURCE"
  "PERL=${STAGE_PYTHON_HOST_PERL}"
  "MAKEINFO=true"
  "HELP2MAN=true")
if(STAGE_PYTHON_HOST_M4)
  list(APPEND STAGE_PYTHON_COMMON_AUTOTOOLS_ENV "M4=${STAGE_PYTHON_HOST_M4}")
endif()

stage_python_get_no_doc_install_commands(
  "${STAGE_PYTHON_ROOTFS_DIR}"
  "${STAGE_PYTHON_INSTALL_PREFIX}"
  STAGE_PYTHON_NO_DOC_INSTALL_COMMANDS)

set(_stage_python_sysroot_stage_stamp "${STAGE_PYTHON_ROOTFS_DIR}/.sysroot-staged")
add_custom_command(
  OUTPUT "${_stage_python_sysroot_stage_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${STAGE_PYTHON_ROOTFS_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE_PYTHON_ROOTFS_DIR}"
  COMMAND "${STAGE_PYTHON_CP_PROGRAM}" -a "${STAGE_PYTHON_INPUT_ROOTFS_DIR}/." "${STAGE_PYTHON_ROOTFS_DIR}/"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE_PYTHON_ROOTFS_DIR}/root"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_sysroot_stage_stamp}"
  DEPENDS "${STAGE_PYTHON_INPUT_ROOTFS_DIR}/usr"
  COMMENT "Staging stage1 rootfs into ${STAGE_PYTHON_ROOTFS_DIR}"
  VERBATIM)

add_custom_target(stage-python-sysroot-staged
  DEPENDS "${_stage_python_sysroot_stage_stamp}")

set(_stage_python_rootfs_deps stage-python-sysroot-staged)

if(COMMAND stage_python_register_build_tool_packages)
  stage_python_register_build_tool_packages(_stage_python_build_tool_targets stage-python-sysroot-staged)
  if(_stage_python_build_tool_targets)
    list(APPEND _stage_python_rootfs_deps ${_stage_python_build_tool_targets})
  endif()
endif()

if(COMMAND stage_python_register_python_support_packages)
  stage_python_register_python_support_packages(_stage_python_python_support_targets stage-python-sysroot-staged)
  if(_stage_python_python_support_targets)
    list(APPEND _stage_python_rootfs_deps ${_stage_python_python_support_targets})
  endif()
endif()

if(COMMAND stage_python_register_interpreter_packages)
  stage_python_register_interpreter_packages(_stage_python_interpreter_targets stage-python-sysroot-staged)
  if(_stage_python_interpreter_targets)
    list(APPEND _stage_python_rootfs_deps ${_stage_python_interpreter_targets})
  endif()
endif()

add_custom_target(stage-python-rootfs ALL
  DEPENDS ${_stage_python_rootfs_deps})

message(STATUS "stage_python target triple   : ${STAGE_PYTHON_TARGET_TRIPLE}")
message(STATUS "stage_python build triple    : ${STAGE_PYTHON_BUILD_TRIPLE}")
message(STATUS "stage_python clang root      : ${STAGE_PYTHON_CLANG_ROOT}")
message(STATUS "stage_python llvm archive    : ${STAGE_PYTHON_LLVM_ARCHIVE}")
message(STATUS "stage_python input rootfs    : ${STAGE_PYTHON_INPUT_ROOTFS_DIR}")
message(STATUS "stage_python output rootfs   : ${STAGE_PYTHON_ROOTFS_DIR}")
message(STATUS "stage_python install prefix  : ${STAGE_PYTHON_INSTALL_PREFIX}")
message(STATUS "stage_python runtime lib dir : ${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}")
message(STATUS "stage_python resource dir    : ${STAGE_PYTHON_TARGET_CLANG_RESOURCE_DIR}")
message(STATUS "stage_python jobs            : ${STAGE_PYTHON_JOBS}")
if(COMMAND stage_python_register_build_tool_packages)
  message(STATUS "stage_python build tools     : ${_stage_python_build_tool_targets}")
  message(STATUS "stage_python ninja source    : ${STAGE_PYTHON_NINJA_SOURCE_DIR}")
  message(STATUS "stage_python bison source    : ${STAGE_PYTHON_BISON_SOURCE_DIR}")
  message(STATUS "stage_python flex source     : ${STAGE_PYTHON_FLEX_SOURCE_DIR}")
else()
  message(STATUS "stage_python build tools     : disabled")
endif()
if(COMMAND stage_python_register_python_support_packages)
  message(STATUS "stage_python python libs     : ${_stage_python_python_support_targets}")
  message(STATUS "stage_python libffi source   : ${STAGE_PYTHON_LIBFFI_SOURCE_DIR}")
  message(STATUS "stage_python uuid source     : ${STAGE_PYTHON_UTIL_LINUX_SOURCE_DIR}")
  message(STATUS "stage_python expat source    : ${STAGE_PYTHON_LIBEXPAT_SOURCE_DIR}")
  message(STATUS "stage_python sqlite source   : ${STAGE_PYTHON_SQLITE_SOURCE_DIR}")
  message(STATUS "stage_python gdbm source     : ${STAGE_PYTHON_GDBM_SOURCE_DIR}")
  message(STATUS "stage_python iconv source    : ${STAGE_PYTHON_LIBICONV_SOURCE_DIR}")
  message(STATUS "stage_python libxml2 source  : ${STAGE_PYTHON_LIBXML2_SOURCE_DIR}")
  message(STATUS "stage_python libxslt source  : ${STAGE_PYTHON_LIBXSLT_SOURCE_DIR}")
else()
  message(STATUS "stage_python python libs     : disabled")
endif()
if(COMMAND stage_python_register_interpreter_packages)
  message(STATUS "stage_python interpreters    : ${_stage_python_interpreter_targets}")
  message(STATUS "stage_python python source   : ${STAGE_PYTHON_PYTHON_SOURCE_DIR}")
else()
  message(STATUS "stage_python interpreters    : disabled")
endif()
