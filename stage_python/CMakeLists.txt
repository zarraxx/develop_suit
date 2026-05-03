cmake_minimum_required(VERSION 3.24)

project(stage_python LANGUAGES NONE)

include(ProcessorCount)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonHelpers.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonHostBuild.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonBuildToolPackages.cmake)

set(STAGE_PYTHON_CACHE_DIR "${CMAKE_CURRENT_LIST_DIR}/../cache" CACHE PATH "Directory containing downloaded archives")
set(STAGE_PYTHON_WORK_DIR "${CMAKE_BINARY_DIR}/stage-python-work" CACHE PATH "Working directory used by stage_python")
set(STAGE_PYTHON_SOURCE_DIR "${STAGE_PYTHON_WORK_DIR}/src" CACHE PATH "Extracted third-party source trees")
set(STAGE_PYTHON_TMP_DIR "${STAGE_PYTHON_WORK_DIR}/tmp" CACHE PATH "Temporary directory used by build tools instead of /tmp")
set(STAGE_PYTHON_OUTPUT_DIR "${CMAKE_BINARY_DIR}/out" CACHE PATH "Build output directory")
set(STAGE_PYTHON_INSTALL_DIR "${STAGE_PYTHON_OUTPUT_DIR}/host" CACHE PATH "Install prefix used by stage_python host tools")
set(STAGE_PYTHON_PACKAGE_BUILD_ROOT "${CMAKE_BINARY_DIR}/packages" CACHE PATH "Per-package build directory root")
set(STAGE_PYTHON_STAMP_DIR "${CMAKE_BINARY_DIR}/stamps" CACHE PATH "Stamp directory for stage_python package installs")

option(STAGE_PYTHON_DOWNLOAD_MISSING "Automatically download missing archives into STAGE_PYTHON_CACHE_DIR during configure" ON)

ProcessorCount(_stage_python_default_jobs)
if(NOT _stage_python_default_jobs)
  set(_stage_python_default_jobs 1)
endif()
set(STAGE_PYTHON_JOBS "${_stage_python_default_jobs}" CACHE STRING "Parallel build job count passed to make and nested cmake builds")

find_program(STAGE_PYTHON_HOST_CC NAMES cc clang gcc REQUIRED)
find_program(STAGE_PYTHON_HOST_CXX NAMES c++ clang++ g++ REQUIRED)
find_program(STAGE_PYTHON_MAKE_PROGRAM NAMES gmake make REQUIRED)
find_program(STAGE_PYTHON_HOST_PERL NAMES perl)
find_program(STAGE_PYTHON_HOST_M4 NAMES gm4 m4)

set(STAGE_PYTHON_COMMON_HOST_ENV
  "TMPDIR=${STAGE_PYTHON_TMP_DIR}"
  "TMP=${STAGE_PYTHON_TMP_DIR}"
  "TEMP=${STAGE_PYTHON_TMP_DIR}"
  "TEMPDIR=${STAGE_PYTHON_TMP_DIR}"
  "PATH=$ENV{PATH}"
  "CC=${STAGE_PYTHON_HOST_CC}"
  "CXX=${STAGE_PYTHON_HOST_CXX}"
  "CPP=${STAGE_PYTHON_HOST_CC} -E")

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

file(MAKE_DIRECTORY "${STAGE_PYTHON_SOURCE_DIR}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_TMP_DIR}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_INSTALL_DIR}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}")
file(MAKE_DIRECTORY "${STAGE_PYTHON_STAMP_DIR}")

stage_python_register_build_tool_packages(_stage_python_build_tool_packages)

if(_stage_python_build_tool_packages)
  add_custom_target(stage-python-tools ALL
    DEPENDS ${_stage_python_build_tool_packages})
else()
  add_custom_target(stage-python-tools ALL)
endif()

message(STATUS "stage_python cache dir    : ${STAGE_PYTHON_CACHE_DIR}")
message(STATUS "stage_python work dir     : ${STAGE_PYTHON_WORK_DIR}")
message(STATUS "stage_python source dir   : ${STAGE_PYTHON_SOURCE_DIR}")
message(STATUS "stage_python tmp dir      : ${STAGE_PYTHON_TMP_DIR}")
message(STATUS "stage_python output dir   : ${STAGE_PYTHON_OUTPUT_DIR}")
message(STATUS "stage_python install dir  : ${STAGE_PYTHON_INSTALL_DIR}")
message(STATUS "stage_python jobs         : ${STAGE_PYTHON_JOBS}")
message(STATUS "stage_python build tools  : ${_stage_python_build_tool_packages}")
if(STAGE_PYTHON_ENABLE_NINJA)
  message(STATUS "stage_python ninja source : ${STAGE_PYTHON_NINJA_SOURCE_DIR}")
endif()
if(STAGE_PYTHON_ENABLE_BISON)
  message(STATUS "stage_python bison source : ${STAGE_PYTHON_BISON_SOURCE_DIR}")
endif()
if(STAGE_PYTHON_ENABLE_FLEX)
  message(STATUS "stage_python flex source  : ${STAGE_PYTHON_FLEX_SOURCE_DIR}")
endif()
