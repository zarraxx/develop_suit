include_guard(GLOBAL)

include(CMakeParseArguments)

function(stage_python_add_autotools_package target_name)
  set(options BUILD_IN_SOURCE)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX CONFIGURE_PATH BUILD_TRIPLE HOST_TRIPLE)
  set(multiValueArgs CONFIGURE_ARGS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage_python_add_autotools_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}")
  endif()

  if(NOT DEFINED PKG_CONFIGURE_PATH OR "${PKG_CONFIGURE_PATH}" STREQUAL "")
    set(PKG_CONFIGURE_PATH "${PKG_SOURCE_DIR}/configure")
  endif()

  if(NOT EXISTS "${PKG_CONFIGURE_PATH}")
    message(FATAL_ERROR
      "Configure script for ${PKG_PACKAGE_NAME} does not exist: ${PKG_CONFIGURE_PATH}")
  endif()

  if(NOT DEFINED PKG_BUILD_TRIPLE OR "${PKG_BUILD_TRIPLE}" STREQUAL "")
    set(PKG_BUILD_TRIPLE "${STAGE_PYTHON_BUILD_TRIPLE}")
  endif()

  if(NOT DEFINED PKG_HOST_TRIPLE OR "${PKG_HOST_TRIPLE}" STREQUAL "")
    set(PKG_HOST_TRIPLE "${STAGE_PYTHON_TARGET_TRIPLE}")
  endif()

  if(PKG_BUILD_IN_SOURCE)
    set(_stage_python_build_dir "${PKG_SOURCE_DIR}")
  else()
    set(_stage_python_build_dir "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  endif()

  set(_stage_python_stamp_file "${STAGE_PYTHON_ROOTFS_DIR}/.${PKG_PACKAGE_NAME}-installed")
  set(_stage_python_parallel_args "")
  if(STAGE_PYTHON_JOBS)
    list(APPEND _stage_python_parallel_args "-j${STAGE_PYTHON_JOBS}")
  endif()

  set(_stage_python_env
    ${STAGE_PYTHON_COMMON_AUTOTOOLS_ENV}
    ${PKG_ENV})
  set(_stage_python_depends ${PKG_DEPENDS} "${PKG_CONFIGURE_PATH}")

  set(_stage_python_clean_build_dir_commands)
  if(NOT PKG_BUILD_IN_SOURCE)
    list(APPEND _stage_python_clean_build_dir_commands
      COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage_python_build_dir}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage_python_build_dir}")
  endif()

  stage_python_collect_triplet_refresh_commands("${PKG_SOURCE_DIR}" _stage_python_triplet_refresh_commands)

  add_custom_command(
    OUTPUT "${_stage_python_stamp_file}"
    ${_stage_python_clean_build_dir_commands}
    ${_stage_python_triplet_refresh_commands}
    COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage_python_build_dir}"
      "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${PKG_CONFIGURE_PATH}"
      "--host=${PKG_HOST_TRIPLE}"
      "--build=${PKG_BUILD_TRIPLE}"
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
      "DESTDIR=${STAGE_PYTHON_ROOTFS_DIR}"
      install
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_stamp_file}"
    DEPENDS ${_stage_python_depends}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE_PYTHON_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage_python_stamp_file}")
endfunction()

function(stage_python_add_cmake_package target_name)
  set(options)
  set(oneValueArgs PACKAGE_NAME SOURCE_DIR INSTALL_PREFIX)
  set(multiValueArgs CMAKE_ARGS ENV DEPENDS POST_INSTALL_COMMANDS)
  cmake_parse_arguments(PKG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT DEFINED PKG_PACKAGE_NAME OR "${PKG_PACKAGE_NAME}" STREQUAL "")
    set(PKG_PACKAGE_NAME "${target_name}")
  endif()

  if(NOT DEFINED PKG_SOURCE_DIR OR "${PKG_SOURCE_DIR}" STREQUAL "")
    message(FATAL_ERROR "stage_python_add_cmake_package(${target_name}) requires SOURCE_DIR")
  endif()

  if(NOT EXISTS "${PKG_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
      "CMake project for ${PKG_PACKAGE_NAME} does not exist: ${PKG_SOURCE_DIR}/CMakeLists.txt")
  endif()

  if(NOT DEFINED PKG_INSTALL_PREFIX OR "${PKG_INSTALL_PREFIX}" STREQUAL "")
    set(PKG_INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}")
  endif()

  set(_stage_python_build_dir "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}/${PKG_PACKAGE_NAME}")
  set(_stage_python_stamp_file "${STAGE_PYTHON_ROOTFS_DIR}/.${PKG_PACKAGE_NAME}-installed")
  set(_stage_python_env
    ${STAGE_PYTHON_COMMON_TARGET_BUILD_ENV}
    ${PKG_ENV})
  set(_stage_python_depends ${PKG_DEPENDS} "${PKG_SOURCE_DIR}/CMakeLists.txt")

  set(_stage_python_build_parallel_args "")
  if(STAGE_PYTHON_JOBS)
    list(APPEND _stage_python_build_parallel_args --parallel "${STAGE_PYTHON_JOBS}")
  endif()

  add_custom_command(
    OUTPUT "${_stage_python_stamp_file}"
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
      "-DCMAKE_SYSTEM_NAME=Linux"
      "-DCMAKE_SYSTEM_PROCESSOR=${STAGE_PYTHON_TARGET_ARCH}"
      "-DCMAKE_SYSROOT=${STAGE_PYTHON_ROOTFS_DIR}"
      "-DCMAKE_FIND_ROOT_PATH=${STAGE_PYTHON_ROOTFS_DIR}"
      "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
      "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
      "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
      "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
      "-DCMAKE_C_COMPILER=${STAGE_PYTHON_TARGET_CC_WRAPPER}"
      "-DCMAKE_CXX_COMPILER=${STAGE_PYTHON_TARGET_CXX_WRAPPER}"
      "-DCMAKE_AR=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-ar"
      "-DCMAKE_NM=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-nm"
      "-DCMAKE_OBJCOPY=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-objcopy"
      "-DCMAKE_RANLIB=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-ranlib"
      "-DCMAKE_STRIP=${STAGE_PYTHON_LLVM_BIN_DIR}/llvm-strip"
      ${PKG_CMAKE_ARGS}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      "${CMAKE_COMMAND}"
      --build "${_stage_python_build_dir}"
      ${_stage_python_build_parallel_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_env}
      DESTDIR=${STAGE_PYTHON_ROOTFS_DIR}
      "${CMAKE_COMMAND}"
      --install "${_stage_python_build_dir}"
    ${PKG_POST_INSTALL_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_stamp_file}"
    DEPENDS ${_stage_python_depends}
    COMMENT "Building ${PKG_PACKAGE_NAME} for ${STAGE_PYTHON_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target("${target_name}" DEPENDS "${_stage_python_stamp_file}")
endfunction()
