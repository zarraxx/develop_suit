include_guard(GLOBAL)

include(CMakeParseArguments)

function(stage1_add_autotools_package target_name)
  set(options BUILD_IN_SOURCE)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX CONFIGURE_PATH)
  set(multiValueArgs CONFIGURE_ARGS ENV DEPENDS)
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

  add_custom_command(
    OUTPUT "${_stage1_stamp_file}"
    ${_stage1_clean_build_dir_commands}
    COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage1_build_dir}"
      "${CMAKE_COMMAND}" -E env
      ${_stage1_env}
      "${PKG_CONFIGURE_PATH}"
      "--host=${STAGE1_TARGET_TRIPLE}"
      "--build=${STAGE1_BUILD_TRIPLE}"
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
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
    DEPENDS ${_stage1_depends}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE1_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage1_stamp_file}")
endfunction()
