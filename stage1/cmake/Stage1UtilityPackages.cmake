include_guard(GLOBAL)

set(STAGE1_UTILITY_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")

set(STAGE1_PATCHELF_ARCHIVE "" CACHE FILEPATH "Path to the patchelf source archive")
set(STAGE1_CURL_ARCHIVE "" CACHE FILEPATH "Path to the curl source archive")

set(STAGE1_PATCHELF_SOURCE_DIR "" CACHE PATH "Direct path to the patchelf source tree")
set(STAGE1_CURL_SOURCE_DIR "" CACHE PATH "Direct path to the curl source tree")

set(STAGE1_PATCHELF_URL
  "https://github.com/NixOS/patchelf/releases/download/0.15.5/patchelf-0.15.5.tar.gz"
  CACHE STRING
  "Download URL for patchelf")
set(STAGE1_CURL_URL
  "https://curl.se/download/curl-8.20.0.tar.gz"
  CACHE STRING
  "Download URL for curl")

option(STAGE1_ENABLE_UTILITY_PACKAGES "Build utility packages in stage1" ON)
option(STAGE1_ENABLE_LDD "Install an ldd helper script in stage1" ON)
option(STAGE1_ENABLE_PATCHELF "Build patchelf in stage1" ON)
option(STAGE1_ENABLE_CURL "Build curl in stage1" ON)

set(STAGE1_UTILITY_PACKAGE_NAMES
  ldd
  patchelf
  curl)

function(stage1_register_utility_packages out_targets_var sysroot_stage_dep)
  if(NOT STAGE1_ENABLE_UTILITY_PACKAGES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  if(NOT STAGE1_ENABLE_LDD AND NOT STAGE1_ENABLE_PATCHELF AND NOT STAGE1_ENABLE_CURL)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  if(STAGE1_ENABLE_CURL AND NOT STAGE1_ENABLE_OPENSSL)
    message(FATAL_ERROR "stage1 curl requires STAGE1_ENABLE_OPENSSL=ON")
  endif()

  if(STAGE1_ENABLE_CURL AND NOT STAGE1_ENABLE_ZLIB)
    message(FATAL_ERROR "stage1 curl requires STAGE1_ENABLE_ZLIB=ON")
  endif()

  find_program(STAGE1_MAKE_PROGRAM NAMES gmake make REQUIRED)
  find_file(STAGE1_HOST_CONFIG_SUB
    NAMES config.sub
    PATHS
      /usr/share/misc
      /usr/share/automake-1.18
      /usr/share/automake-1.17
      /usr/share/automake-1.16
    NO_DEFAULT_PATH)
  find_file(STAGE1_HOST_CONFIG_GUESS
    NAMES config.guess
    PATHS
      /usr/share/misc
      /usr/share/automake-1.18
      /usr/share/automake-1.17
      /usr/share/automake-1.16
    NO_DEFAULT_PATH)

  if(STAGE1_ENABLE_PATCHELF)
    stage1_resolve_archive_source(
      STAGE1_PATCHELF_SOURCE_DIR
      "patchelf"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/patchelf"
      "configure"
      SOURCE_DIR "${STAGE1_PATCHELF_SOURCE_DIR}"
      ARCHIVE "${STAGE1_PATCHELF_ARCHIVE}"
      DEFAULT_ARCHIVE "patchelf-0.15.5.tar.gz"
      URL "${STAGE1_PATCHELF_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/patchelf-*.tar.gz")
  endif()

  if(STAGE1_ENABLE_CURL)
    stage1_resolve_archive_source(
      STAGE1_CURL_SOURCE_DIR
      "curl"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/curl"
      "configure"
      SOURCE_DIR "${STAGE1_CURL_SOURCE_DIR}"
      ARCHIVE "${STAGE1_CURL_ARCHIVE}"
      DEFAULT_ARCHIVE "curl-8.20.0.tar.gz"
      URL "${STAGE1_CURL_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/curl-*.tar.gz")
  endif()

  set(_stage1_targets "")
  set(_stage1_prefix_root "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}")
  stage1_get_no_doc_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_no_doc_install_commands)

  if(STAGE1_ENABLE_LDD)
    stage1_detect_elf_interpreter(
      "${STAGE1_INPUT_ROOTFS_DIR}/bin/busybox"
      _stage1_target_dynamic_linker)
    set(_stage1_ldd_library_dirs
      "/lib64:/lib:/usr/lib64:/usr/lib:/usr/lib/${STAGE1_TARGET_TRIPLE}")
    set(_stage1_ldd_output "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/bin/ldd")
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/generated")
    configure_file(
      "${STAGE1_UTILITY_CMAKE_DIR}/ldd.in"
      "${CMAKE_BINARY_DIR}/generated/stage1-ldd-${STAGE1_TARGET_TRIPLE}.sh"
      @ONLY)
    set(_stage1_ldd_source "${CMAKE_BINARY_DIR}/generated/stage1-ldd-${STAGE1_TARGET_TRIPLE}.sh")
    add_custom_command(
      OUTPUT "${_stage1_ldd_output}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}/bin"
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_stage1_ldd_source}" "${_stage1_ldd_output}"
      COMMAND chmod 755 "${_stage1_ldd_output}"
      DEPENDS "${sysroot_stage_dep}" "${_stage1_ldd_source}"
      COMMENT "Installing stage1 ldd helper"
      VERBATIM)
    add_custom_target(stage1-ldd DEPENDS "${_stage1_ldd_output}")
    list(APPEND _stage1_targets stage1-ldd)
  endif()

  if(STAGE1_ENABLE_PATCHELF)
    stage1_add_configure_make_package(
      stage1-patchelf
      PACKAGE_NAME "patchelf"
      SOURCE_DIR "${STAGE1_PATCHELF_SOURCE_DIR}"
      CONFIGURE_PATH "${STAGE1_PATCHELF_SOURCE_DIR}/configure"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-patchelf)
  endif()

  if(STAGE1_ENABLE_CURL)
    find_program(STAGE1_HOST_PKG_CONFIG NAMES pkgconf pkg-config REQUIRED)

    set(_stage1_curl_deps
      "${sysroot_stage_dep}"
      stage1-openssl
      stage1-zlib)
    if(TARGET stage1-ca-certificates)
      list(APPEND _stage1_curl_deps stage1-ca-certificates)
    endif()

    set(_stage1_curl_pkgconfig_libdir
      "${_stage1_prefix_root}/lib/pkgconfig:${_stage1_prefix_root}/lib/${STAGE1_TARGET_TRIPLE}/pkgconfig:${_stage1_prefix_root}/share/pkgconfig")

    stage1_add_configure_make_package(
      stage1-curl
      PACKAGE_NAME "curl"
      SOURCE_DIR "${STAGE1_CURL_SOURCE_DIR}"
      CONFIGURE_PATH "${STAGE1_CURL_SOURCE_DIR}/configure"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CONFIGURE_ARGS
        --with-openssl=${_stage1_prefix_root}
        --with-zlib=${_stage1_prefix_root}
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt
        --with-ca-path=/etc/ssl/certs
        --enable-shared
        --enable-static
        --disable-ldap
        --disable-ldaps
        --disable-manual
        --without-brotli
        --without-libidn2
        --without-libpsl
        --without-libssh2
        --without-librtmp
        --without-nghttp2
        --without-nghttp3
        --without-ngtcp2
        --without-zstd
      ENV
        "PKG_CONFIG=${STAGE1_HOST_PKG_CONFIG}"
        "PKG_CONFIG_LIBDIR=${_stage1_curl_pkgconfig_libdir}"
        "PKG_CONFIG_PATH="
        "PKG_CONFIG_SYSROOT_DIR=${STAGE1_ROOTFS_DIR}"
        "CPPFLAGS=-I${_stage1_prefix_root}/include"
        "LDFLAGS=-L${_stage1_prefix_root}/lib -L${STAGE1_TARGET_RUNTIME_LIBDIR}"
      POST_INSTALL_COMMANDS
        ${_stage1_no_doc_install_commands}
      DEPENDS ${_stage1_curl_deps})
    list(APPEND _stage1_targets stage1-curl)
  endif()

  set(STAGE1_PATCHELF_SOURCE_DIR "${STAGE1_PATCHELF_SOURCE_DIR}" PARENT_SCOPE)
  set(STAGE1_CURL_SOURCE_DIR "${STAGE1_CURL_SOURCE_DIR}" PARENT_SCOPE)
  set(${out_targets_var} "${_stage1_targets}" PARENT_SCOPE)
endfunction()
