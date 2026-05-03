cmake_minimum_required(VERSION 3.24)

project(stage_python LANGUAGES NONE)

include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonHelpers.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/cmake/StagePythonBuildToolPackages.cmake)

set(STAGE_PYTHON_CACHE_DIR "${CMAKE_CURRENT_LIST_DIR}/../cache" CACHE PATH "Directory containing downloaded archives")
set(STAGE_PYTHON_WORK_DIR "${CMAKE_BINARY_DIR}/stage-python-work" CACHE PATH "Working directory used by stage_python")
set(STAGE_PYTHON_SOURCE_DIR "${STAGE_PYTHON_WORK_DIR}/src" CACHE PATH "Extracted third-party source trees")

option(STAGE_PYTHON_DOWNLOAD_MISSING "Automatically download missing archives into STAGE_PYTHON_CACHE_DIR during configure" ON)

stage_python_register_build_tool_packages(_stage_python_build_tool_packages)

message(STATUS "stage_python cache dir    : ${STAGE_PYTHON_CACHE_DIR}")
message(STATUS "stage_python work dir     : ${STAGE_PYTHON_WORK_DIR}")
message(STATUS "stage_python source dir   : ${STAGE_PYTHON_SOURCE_DIR}")
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
