include_guard(GLOBAL)

set(STAGE_PYTHON_PYTHON_ARCHIVE "" CACHE FILEPATH "Path to the Python source archive")
set(STAGE_PYTHON_PYTHON_SOURCE_DIR "" CACHE PATH "Direct path to the Python source tree")

set(STAGE_PYTHON_PYTHON_URL
  "https://www.python.org/ftp/python/3.14.4/Python-3.14.4.tar.xz"
  CACHE STRING
  "Download URL for Python")

option(STAGE_PYTHON_ENABLE_INTERPRETER_PACKAGES "Build interpreter packages in stage_python" ON)
option(STAGE_PYTHON_ENABLE_PYTHON "Build CPython in stage_python" ON)

function(stage_python_register_interpreter_packages out_var sysroot_stage_dep)
  if(NOT STAGE_PYTHON_ENABLE_INTERPRETER_PACKAGES OR NOT STAGE_PYTHON_ENABLE_PYTHON)
    set(${out_var} "" PARENT_SCOPE)
    return()
  endif()

  file(MAKE_DIRECTORY "${STAGE_PYTHON_SOURCE_DIR}")

  stage_python_resolve_archive_source(
    STAGE_PYTHON_PYTHON_SOURCE_DIR
    "Python"
    "${STAGE_PYTHON_CACHE_DIR}"
    "${STAGE_PYTHON_SOURCE_DIR}/python"
    "configure"
    SOURCE_DIR "${STAGE_PYTHON_PYTHON_SOURCE_DIR}"
    ARCHIVE "${STAGE_PYTHON_PYTHON_ARCHIVE}"
    DEFAULT_ARCHIVE "Python-3.14.4.tar.xz"
    URL "${STAGE_PYTHON_PYTHON_URL}"
    GLOB_PATTERNS
      "${STAGE_PYTHON_CACHE_DIR}/Python-3.14.*.tar.xz"
      "${STAGE_PYTHON_CACHE_DIR}/Python-3.14.*.tar.gz")

  find_program(STAGE_PYTHON_HOST_PKG_CONFIG NAMES pkgconf pkg-config REQUIRED)

  set(_stage_python_targets "")
  set(_stage_python_cross_build FALSE)
  if(NOT STAGE_PYTHON_BUILD_TRIPLE STREQUAL STAGE_PYTHON_TARGET_TRIPLE)
    set(_stage_python_cross_build TRUE)
  endif()

  set(_stage_python_pkg_config_libdir
    "${STAGE_PYTHON_PREFIX_ROOT}/lib/pkgconfig:${STAGE_PYTHON_PREFIX_ROOT}/lib/${STAGE_PYTHON_TARGET_TRIPLE}/pkgconfig:${STAGE_PYTHON_PREFIX_ROOT}/share/pkgconfig")
  set(_stage_python_pkg_config_env
    "PKG_CONFIG=${STAGE_PYTHON_HOST_PKG_CONFIG}"
    "PKG_CONFIG_LIBDIR=${_stage_python_pkg_config_libdir}"
    "PKG_CONFIG_PATH="
    "PKG_CONFIG_SYSROOT_DIR=${STAGE_PYTHON_ROOTFS_DIR}")

  set(_stage_python_python_cppflags
    "-I${STAGE_PYTHON_PREFIX_ROOT}/include"
    "-I${STAGE_PYTHON_PREFIX_ROOT}/include/uuid"
    "-I${STAGE_PYTHON_PREFIX_ROOT}/include/ncursesw"
    "-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include"
    "-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include/uuid"
    "-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include/ncursesw")
  list(JOIN _stage_python_python_cppflags " " _stage_python_python_cppflags_joined)

  set(_stage_python_python_ldflags
    "-L${STAGE_PYTHON_PREFIX_ROOT}/lib"
    "-L${STAGE_PYTHON_PREFIX_ROOT}/lib64"
    "-L${STAGE_PYTHON_PREFIX_ROOT}/lib/${STAGE_PYTHON_TARGET_TRIPLE}"
    "-L${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}")
  list(JOIN _stage_python_python_ldflags " " _stage_python_python_ldflags_joined)

  set(_stage_python_python_lib_env
    ${_stage_python_pkg_config_env}
    "CPPFLAGS=${_stage_python_python_cppflags_joined}"
    "LDFLAGS=${_stage_python_python_ldflags_joined}"
    "LIBUUID_CFLAGS=-I${STAGE_PYTHON_PREFIX_ROOT}/include/uuid"
    "LIBUUID_LIBS=-luuid"
    "LIBSQLITE3_CFLAGS=-I${STAGE_PYTHON_PREFIX_ROOT}/include"
    "LIBSQLITE3_LIBS=-lsqlite3"
    "GDBM_CFLAGS=-I${STAGE_PYTHON_PREFIX_ROOT}/include"
    "GDBM_LIBS=-lgdbm"
    "LIBREADLINE_CFLAGS=-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include"
    "LIBREADLINE_LIBS=-lreadline -lncursesw"
    "ZLIB_CFLAGS=-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include"
    "ZLIB_LIBS=-lz"
    "BZIP2_CFLAGS=-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include"
    "BZIP2_LIBS=-lbz2"
    "LIBLZMA_CFLAGS=-I${STAGE_PYTHON_ROOTFS_DIR}/usr/include"
    "LIBLZMA_LIBS=-llzma")

  set(_stage_python_python_configure_args
    "--enable-shared"
    "--with-openssl=${STAGE_PYTHON_PREFIX_ROOT}"
    "--with-system-expat"
    "--with-ensurepip=no")

  if(NOT _stage_python_cross_build)
    list(APPEND _stage_python_python_configure_args "--enable-optimizations")
  endif()

  set(_stage_python_python_depends
    "${sysroot_stage_dep}"
    "${STAGE_PYTHON_PYTHON_SOURCE_DIR}/configure")
  foreach(_stage_python_dep_target IN ITEMS
      stage-python-libffi
      stage-python-uuid
      stage-python-libexpat
      stage-python-sqlite
      stage-python-gdbm
      stage-python-libiconv)
    if(TARGET "${_stage_python_dep_target}")
      list(APPEND _stage_python_python_depends "${_stage_python_dep_target}")
    endif()
  endforeach()

  set(_stage_python_build_python_env
    "TMPDIR=${STAGE_PYTHON_TMP_DIR}"
    "TMP=${STAGE_PYTHON_TMP_DIR}"
    "TEMP=${STAGE_PYTHON_TMP_DIR}"
    "TEMPDIR=${STAGE_PYTHON_TMP_DIR}"
    "PATH=${STAGE_PYTHON_LLVM_BIN_DIR}:$ENV{PATH}"
    "CC=${STAGE_PYTHON_HOST_CC}"
    "CXX=${STAGE_PYTHON_HOST_CXX}")

  set(_stage_python_target_python_env
    ${STAGE_PYTHON_COMMON_AUTOTOOLS_ENV}
    ${_stage_python_python_lib_env})

  set(_stage_python_target_python_configure_args
    ${_stage_python_python_configure_args})

  set(_stage_python_target_python_depends
    ${_stage_python_python_depends})

  if(_stage_python_cross_build)
    set(_stage_python_build_python_dir "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}/python-build-python")
    set(_stage_python_build_python_stamp "${_stage_python_build_python_dir}/.build-python-ready")
    set(_stage_python_build_python_binary "${_stage_python_build_python_dir}/python")
    set(_stage_python_config_site "${STAGE_PYTHON_TOOLCHAIN_DIR}/python-${STAGE_PYTHON_TARGET_TRIPLE}.config.site")

    file(WRITE "${_stage_python_config_site}"
      "ac_cv_buggy_getaddrinfo=no\n"
      "ac_cv_file__dev_ptmx=yes\n"
      "ac_cv_file__dev_ptc=no\n")

    add_custom_command(
      OUTPUT "${_stage_python_build_python_stamp}"
      COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage_python_build_python_dir}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage_python_build_python_dir}"
      COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage_python_build_python_dir}"
        "${CMAKE_COMMAND}" -E env
        ${_stage_python_build_python_env}
        "${STAGE_PYTHON_PYTHON_SOURCE_DIR}/configure"
        "--prefix=/usr"
        "--with-ensurepip=no"
      COMMAND "${CMAKE_COMMAND}" -E env
        ${_stage_python_build_python_env}
        "${STAGE_PYTHON_MAKE_PROGRAM}"
        -C "${_stage_python_build_python_dir}"
        "-j${STAGE_PYTHON_JOBS}"
      COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_build_python_stamp}"
      DEPENDS "${STAGE_PYTHON_PYTHON_SOURCE_DIR}/configure"
      COMMENT "Building host Python helper for cross-compiling ${STAGE_PYTHON_TARGET_TRIPLE}"
      VERBATIM)

    add_custom_target(stage-python-build-python DEPENDS "${_stage_python_build_python_stamp}")
    list(APPEND _stage_python_targets stage-python-build-python)

    list(APPEND _stage_python_target_python_env
      "CONFIG_SITE=${_stage_python_config_site}"
      "HOSTRUNNER="
      "PYTHON_FOR_BUILD=${_stage_python_build_python_binary}")
    list(APPEND _stage_python_target_python_configure_args
      "--with-build-python=${_stage_python_build_python_binary}")
    list(APPEND _stage_python_target_python_depends
      stage-python-build-python
      "${_stage_python_build_python_stamp}")
  else()
    list(APPEND _stage_python_target_python_env
      "LD_LIBRARY_PATH=${STAGE_PYTHON_PREFIX_ROOT}/lib:${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}:$ENV{LD_LIBRARY_PATH}")
  endif()

  set(_stage_python_target_python_build_dir "${STAGE_PYTHON_PACKAGE_BUILD_ROOT}/python")
  set(_stage_python_target_python_stamp "${STAGE_PYTHON_ROOTFS_DIR}/.python-installed")
  set(_stage_python_parallel_args "")
  if(STAGE_PYTHON_JOBS)
    list(APPEND _stage_python_parallel_args "-j${STAGE_PYTHON_JOBS}")
  endif()

  stage_python_collect_triplet_refresh_commands(
    "${STAGE_PYTHON_PYTHON_SOURCE_DIR}"
    _stage_python_triplet_refresh_commands)
  stage_python_get_no_doc_install_commands(
    "${STAGE_PYTHON_ROOTFS_DIR}"
    "${STAGE_PYTHON_INSTALL_PREFIX}"
    _stage_python_no_doc_install_commands)

  add_custom_command(
    OUTPUT "${_stage_python_target_python_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage_python_target_python_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage_python_target_python_build_dir}"
    ${_stage_python_triplet_refresh_commands}
    COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage_python_target_python_build_dir}"
      "${CMAKE_COMMAND}" -E env
      ${_stage_python_target_python_env}
      "${STAGE_PYTHON_PYTHON_SOURCE_DIR}/configure"
      "--host=${STAGE_PYTHON_TARGET_TRIPLE}"
      "--build=${STAGE_PYTHON_BUILD_TRIPLE}"
      "--prefix=${STAGE_PYTHON_INSTALL_PREFIX}"
      ${_stage_python_target_python_configure_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_target_python_env}
      "${STAGE_PYTHON_MAKE_PROGRAM}"
      -C "${_stage_python_target_python_build_dir}"
      ${_stage_python_parallel_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage_python_target_python_env}
      "${STAGE_PYTHON_MAKE_PROGRAM}"
      -C "${_stage_python_target_python_build_dir}"
      "DESTDIR=${STAGE_PYTHON_ROOTFS_DIR}"
      install
    ${_stage_python_no_doc_install_commands}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage_python_target_python_stamp}"
    DEPENDS ${_stage_python_target_python_depends}
    COMMENT "Building Python for ${STAGE_PYTHON_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target(stage-python-python DEPENDS "${_stage_python_target_python_stamp}")
  list(APPEND _stage_python_targets stage-python-python)

  set(${out_var} "${_stage_python_targets}" PARENT_SCOPE)
endfunction()
