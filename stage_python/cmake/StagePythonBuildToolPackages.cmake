include_guard(GLOBAL)

set(STAGE_PYTHON_NINJA_ARCHIVE "" CACHE FILEPATH "Path to the ninja source archive")
set(STAGE_PYTHON_BISON_ARCHIVE "" CACHE FILEPATH "Path to the bison source archive")
set(STAGE_PYTHON_FLEX_ARCHIVE "" CACHE FILEPATH "Path to the flex source archive")

set(STAGE_PYTHON_NINJA_SOURCE_DIR "" CACHE PATH "Direct path to the ninja source tree")
set(STAGE_PYTHON_BISON_SOURCE_DIR "" CACHE PATH "Direct path to the bison source tree")
set(STAGE_PYTHON_FLEX_SOURCE_DIR "" CACHE PATH "Direct path to the flex source tree")

set(STAGE_PYTHON_NINJA_URL
  "https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.2.tar.gz"
  CACHE STRING
  "Download URL for ninja")
set(STAGE_PYTHON_BISON_URL
  "https://ftp.gnu.org/gnu/bison/bison-3.8.tar.xz"
  CACHE STRING
  "Download URL for bison")
set(STAGE_PYTHON_FLEX_URL
  "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz"
  CACHE STRING
  "Download URL for flex")

option(STAGE_PYTHON_ENABLE_BUILD_TOOL_PACKAGES "Enable stage_python build-tool package source resolution" ON)
option(STAGE_PYTHON_ENABLE_NINJA "Enable ninja in stage_python" ON)
option(STAGE_PYTHON_ENABLE_BISON "Enable bison in stage_python" ON)
option(STAGE_PYTHON_ENABLE_FLEX "Enable flex in stage_python" ON)

function(stage_python_register_build_tool_packages out_var)
  if(NOT STAGE_PYTHON_ENABLE_BUILD_TOOL_PACKAGES)
    set(${out_var} "" PARENT_SCOPE)
    return()
  endif()

  file(MAKE_DIRECTORY "${STAGE_PYTHON_SOURCE_DIR}")

  set(_stage_python_targets "")
  set(_stage_python_common_autotools_env
    "CONFIG_SHELL=/bin/sh"
    "SHELL=/bin/sh"
    "MAKEINFO=true"
    "HELP2MAN=true")

  if(STAGE_PYTHON_HOST_M4)
    list(APPEND _stage_python_common_autotools_env "M4=${STAGE_PYTHON_HOST_M4}")
  endif()

  if(STAGE_PYTHON_HOST_PERL)
    list(APPEND _stage_python_common_autotools_env "PERL=${STAGE_PYTHON_HOST_PERL}")
  endif()

  if(STAGE_PYTHON_ENABLE_NINJA)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_NINJA_SOURCE_DIR
      "ninja"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/ninja"
      "CMakeLists.txt"
      SOURCE_DIR "${STAGE_PYTHON_NINJA_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_NINJA_ARCHIVE}"
      DEFAULT_ARCHIVE "ninja-1.13.2.tar.gz"
      URL "${STAGE_PYTHON_NINJA_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/ninja-*.tar.gz"
        "${STAGE_PYTHON_CACHE_DIR}/ninja-*.tar.xz")
    stage_python_add_cmake_host_package(
      stage-python-ninja
      PACKAGE_NAME "ninja"
      SOURCE_DIR "${STAGE_PYTHON_NINJA_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_DIR}"
      CMAKE_ARGS
        "-DBUILD_TESTING=OFF")
    list(APPEND _stage_python_targets stage-python-ninja)
  endif()

  if(STAGE_PYTHON_ENABLE_BISON)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_BISON_SOURCE_DIR
      "bison"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/bison"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_BISON_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_BISON_ARCHIVE}"
      DEFAULT_ARCHIVE "bison-3.8.tar.xz"
      URL "${STAGE_PYTHON_BISON_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/bison-*.tar.xz"
        "${STAGE_PYTHON_CACHE_DIR}/bison-*.tar.gz")
    stage_python_add_autotools_host_package(
      stage-python-bison
      PACKAGE_NAME "bison"
      SOURCE_DIR "${STAGE_PYTHON_BISON_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_DIR}"
      ENV ${_stage_python_common_autotools_env}
      CONFIGURE_ARGS
        "--disable-nls"
        "--disable-dependency-tracking")
    list(APPEND _stage_python_targets stage-python-bison)
  endif()

  if(STAGE_PYTHON_ENABLE_FLEX)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_FLEX_SOURCE_DIR
      "flex"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/flex"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_FLEX_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_FLEX_ARCHIVE}"
      DEFAULT_ARCHIVE "flex-2.6.4.tar.gz"
      URL "${STAGE_PYTHON_FLEX_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/flex-*.tar.gz"
        "${STAGE_PYTHON_CACHE_DIR}/flex-*.tar.xz")
    stage_python_add_autotools_host_package(
      stage-python-flex
      PACKAGE_NAME "flex"
      SOURCE_DIR "${STAGE_PYTHON_FLEX_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_DIR}"
      ENV ${_stage_python_common_autotools_env}
      CONFIGURE_ARGS
        "--disable-nls"
        "--disable-dependency-tracking")
    list(APPEND _stage_python_targets stage-python-flex)
  endif()

  set(${out_var} "${_stage_python_targets}" PARENT_SCOPE)
endfunction()
