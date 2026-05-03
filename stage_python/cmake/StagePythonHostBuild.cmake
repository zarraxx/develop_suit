include_guard(GLOBAL)

include(CMakeParseArguments)

function(stage_python_add_autotools_host_package target_name)
  set(options BUILD_IN_SOURCE)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX CONFIGURE_PATH)
  set(multiValueArgs CONFIGURE_ARGS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage_python_add_autotools_host_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_DIR}")
  endif()

  if(NOT DEFINED PKG_CONFIGURE_PATH OR "${PKG_CONFIGURE_PATH}" STREQUAL "")
    set(PKG_CONFIGURE_PATH "${PKG_SOURCE_DIR}/configure")
  endif()

  if(NOT EXISTS "${PKG_CONFIGURE_PATH}")
    message(FATAL_ERROR
      "Configure script for ${PKG_PACKAGE_NAME} does not exist: ${PKG_CONFIGURE_PATH}")
  endif()

  if(PKG_BUILD_IN_SOURCE)
    set(_stage_python_build_dir "${PKG_SOURCE_DIR}")
  else()
    set(_stage_python_build_dir "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  endif()

  set(_stage_python_stamp_file
    "${STAGE_PYTHON_STAMP_DIR}/${PKG_PACKAGE_NAME}.installed")
  set(_stage_python_parallel_args "")
  if(STAGE_PYTHON_JOBS)
    list(APPEND _stage_python_parallel_args "-j${STAGE_PYTHON_JOBS}")
  endif()

  set(_stage_python_env
    ${STAGE_PYTHON_COMMON_HOST_ENV}
    ${PKG_ENV})
  set(_stage_python_depends
    ${PKG_DEPENDS}
    "${PKG_CONFIGURE_PATH}")

  set(_stage_python_clean_build_dir_commands)
  if(NOT PKG_BUILD_IN_SOURCE)
    list(APPEND _stage_python_clean_build_dir_commands
      COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage_python_build_dir}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage_python_build_dir}")
  endif()

  add_custom_command(
    OUTPUT "${_stage_python_stamp_file}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE_PYTHON_STAMP_DIR}"
    ${_stage_python_clean_build_dir_commands}
    COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage_python_build_dir}"
      "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${PKG_CONFIGURE_PATH}"
      "--prefix=${PKG_INSTALL_PREFIX}"
      ${PKG_CONFIGURE_ARGS}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${STAGE_PYTHON_MAKE_PROGRAM}"
      -C "${_stage_python_build_dir}"
      ${_stage_python_parallel_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${STAGE_PYTHON_MAKE_PROGRAM}"
      -C "${_stage_python_build_dir}"
      install
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_stamp_file}"
    DEPENDS ${_stage_python_depends}
    COMMENT "Building host package ${PKG_PACKAGE_NAME}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage_python_stamp_file}")
endfunction()

function(stage_python_add_cmake_host_package target_name)
  set(options)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX)
  set(multiValueArgs CMAKE_ARGS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage_python_add_cmake_host_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT EXISTS "${PKG_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
      "CMake project for ${PKG_PACKAGE_NAME} does not exist: ${PKG_SOURCE_DIR}/CMakeLists.txt")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_DIR}")
  endif()

  set(_stage_python_build_dir "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  set(_stage_python_stamp_file
    "${STAGE_PYTHON_STAMP_DIR}/${PKG_PACKAGE_NAME}.installed")
  set(_stage_python_env
    ${STAGE_PYTHON_COMMON_HOST_ENV}
    ${PKG_ENV})

  set(_stage_python_build_parallel_args "")
  if(STAGE_PYTHON_JOBS)
    list(APPEND _stage_python_build_parallel_args --parallel "${STAGE_PYTHON_JOBS}")
  endif()

  add_custom_command(
    OUTPUT "${_stage_python_stamp_file}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE_PYTHON_STAMP_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage_python_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage_python_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${CMAKE_COMMAND}"
      -S "${PKG_SOURCE_DIR}"
      -B "${_stage_python_build_dir}"
      ${STAGE_PYTHON_NESTED_CMAKE_GENERATOR_ARGS}
      "-DCMAKE_BUILD_TYPE=Release"
      "-DCMAKE_INSTALL_PREFIX=${PKG_INSTALL_PREFIX}"
      ${PKG_CMAKE_ARGS}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${CMAKE_COMMAND}"
      --build "${_stage_python_build_dir}"
      ${_stage_python_build_parallel_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${CMAKE_COMMAND}"
      --install "${_stage_python_build_dir}"
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_stamp_file}"
    DEPENDS ${PKG_DEPENDS} "${PKG_SOURCE_DIR}/CMakeLists.txt"
    COMMENT "Building host package ${PKG_PACKAGE_NAME}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage_python_stamp_file}")
endfunction()
