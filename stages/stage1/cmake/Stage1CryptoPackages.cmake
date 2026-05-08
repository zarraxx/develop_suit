include_guard(GLOBAL)

include(CMakeParseArguments)

set(STAGE1_CRYPTO_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

set(STAGE1_OPENSSL_ARCHIVE "" CACHE FILEPATH "Path to the OpenSSL source archive")
set(STAGE1_OPENSSL_SOURCE_DIR "" CACHE PATH "Direct path to the OpenSSL source tree")
set(STAGE1_OPENSSL_URL
  "https://github.com/openssl/openssl/releases/download/openssl-3.0.20/openssl-3.0.20.tar.gz"
  CACHE STRING
  "Download URL for OpenSSL")
set(STAGE1_OPENSSL_DIR "/etc/ssl" CACHE STRING "OpenSSL configuration directory inside the target rootfs")
set(STAGE1_CA_CERTIFICATES_BUNDLE "" CACHE FILEPATH "Path to a PEM bundle for ca-certificates")
set(STAGE1_CA_CERTIFICATES_URL
  "https://curl.se/ca/cacert.pem"
  CACHE STRING
  "Download URL for the PEM bundle used as ca-certificates")

option(STAGE1_ENABLE_CRYPTO_PACKAGES "Build crypto libraries in stage1" ON)
option(STAGE1_ENABLE_OPENSSL "Build OpenSSL in stage1" ON)
option(STAGE1_ENABLE_CA_CERTIFICATES "Install ca-certificates bundle in stage1" ON)

set(STAGE1_CRYPTO_PACKAGE_NAMES
  openssl
  ca-certificates)

function(stage1_openssl_configure_target input_arch out_var)
  if(input_arch STREQUAL "x86_64")
    set(_target "linux-x86_64")
  elseif(input_arch STREQUAL "aarch64")
    set(_target "linux-aarch64")
  elseif(input_arch STREQUAL "riscv64")
    set(_target "linux64-riscv64")
  elseif(input_arch STREQUAL "loongarch64")
    set(_target "linux64-loongarch64")
  else()
    message(FATAL_ERROR "Unsupported OpenSSL target arch: ${input_arch}")
  endif()

  set(${out_var} "${_target}" PARENT_SCOPE)
endfunction()

function(stage1_resolve_ca_certificates_bundle out_var)
  if(NOT STAGE1_CA_CERTIFICATES_BUNDLE STREQUAL "")
    if(NOT EXISTS "${STAGE1_CA_CERTIFICATES_BUNDLE}")
      message(FATAL_ERROR "ca-certificates bundle does not exist: ${STAGE1_CA_CERTIFICATES_BUNDLE}")
    endif()
    set(${out_var} "${STAGE1_CA_CERTIFICATES_BUNDLE}" PARENT_SCOPE)
    return()
  endif()

  set(_default_bundle "${STAGE1_CACHE_DIR}/cacert.pem")
  if(NOT EXISTS "${_default_bundle}")
    if(NOT STAGE1_DOWNLOAD_MISSING)
      message(FATAL_ERROR
        "Could not find ca-certificates bundle at ${_default_bundle} and automatic download is disabled.\n"
        "Set STAGE1_DOWNLOAD_MISSING=ON, place the bundle in cache/, or pass -DSTAGE1_CA_CERTIFICATES_BUNDLE=/path/to/cacert.pem.")
    endif()
    stage1_download_file_once(
      "${_default_bundle}"
      "${STAGE1_CA_CERTIFICATES_URL}"
      "ca-certificates bundle")
  endif()

  set(${out_var} "${_default_bundle}" PARENT_SCOPE)
endfunction()

function(stage1_register_crypto_packages out_targets_var sysroot_stage_dep)
  if(NOT STAGE1_ENABLE_CRYPTO_PACKAGES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  if(NOT STAGE1_ENABLE_OPENSSL AND NOT STAGE1_ENABLE_CA_CERTIFICATES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  set(_stage1_targets "")

  if(STAGE1_ENABLE_OPENSSL)
    find_program(STAGE1_HOST_PERL NAMES perl REQUIRED)
    find_program(STAGE1_MAKE_PROGRAM NAMES gmake make REQUIRED)

    stage1_resolve_archive_source(
      STAGE1_OPENSSL_SOURCE_DIR
      "OpenSSL"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/openssl"
      "Configure"
      SOURCE_DIR "${STAGE1_OPENSSL_SOURCE_DIR}"
      ARCHIVE "${STAGE1_OPENSSL_ARCHIVE}"
      DEFAULT_ARCHIVE "openssl-3.0.20.tar.gz"
      URL "${STAGE1_OPENSSL_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/openssl-*.tar.gz")

    stage1_openssl_configure_target("${STAGE1_TARGET_ARCH}" _stage1_openssl_target)

    set(_stage1_package_build_dir "${STAGE1_PACKAGE_BUILD_ROOT}/openssl")
    set(_stage1_stamp_file "${STAGE1_ROOTFS_DIR}/.openssl-installed")
    stage1_get_no_doc_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_no_doc_install_commands)

    add_custom_command(
      OUTPUT "${_stage1_stamp_file}"
      COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage1_package_build_dir}"
      COMMAND "${CMAKE_COMMAND}" -E copy_directory "${STAGE1_OPENSSL_SOURCE_DIR}" "${_stage1_package_build_dir}"
      COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage1_package_build_dir}"
        "${CMAKE_COMMAND}" -E env
        ${STAGE1_COMMON_TARGET_BUILD_ENV}
        "PERL=${STAGE1_HOST_PERL}"
        "HASHBANGPERL=/usr/bin/perl"
        "${STAGE1_HOST_PERL}" ./Configure
        "${_stage1_openssl_target}"
        "--prefix=${STAGE1_INSTALL_PREFIX}"
        "--libdir=lib"
        "--openssldir=${STAGE1_OPENSSL_DIR}"
        "shared"
        "no-tests"
        "no-afalgeng"
        "-Wl,--enable-new-dtags,-rpath,${STAGE1_INSTALL_PREFIX}/lib"
      COMMAND "${CMAKE_COMMAND}" -E env
        ${STAGE1_COMMON_TARGET_BUILD_ENV}
        "PERL=${STAGE1_HOST_PERL}"
        "HASHBANGPERL=/usr/bin/perl"
        "${STAGE1_MAKE_PROGRAM}"
        -C "${_stage1_package_build_dir}"
        "-j${STAGE1_JOBS}"
      COMMAND "${CMAKE_COMMAND}" -E env
        ${STAGE1_COMMON_TARGET_BUILD_ENV}
        "PERL=${STAGE1_HOST_PERL}"
        "HASHBANGPERL=/usr/bin/perl"
        "${STAGE1_MAKE_PROGRAM}"
        -C "${_stage1_package_build_dir}"
        "DESTDIR=${STAGE1_ROOTFS_DIR}"
        install_sw
        install_ssldirs
      ${_stage1_no_doc_install_commands}
      COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
      DEPENDS "${sysroot_stage_dep}"
      COMMENT "Building OpenSSL for ${STAGE1_TARGET_TRIPLE}"
      VERBATIM)

    add_custom_target(stage1-openssl DEPENDS "${_stage1_stamp_file}")
    list(APPEND _stage1_targets stage1-openssl)
  endif()

  if(STAGE1_ENABLE_CA_CERTIFICATES)
    stage1_resolve_ca_certificates_bundle(_stage1_ca_bundle)

    set(_stage1_ca_target_dir "${STAGE1_ROOTFS_DIR}${STAGE1_OPENSSL_DIR}")
    set(_stage1_ca_certs_dir "${_stage1_ca_target_dir}/certs")
    set(_stage1_ca_bundle_target "${_stage1_ca_certs_dir}/ca-certificates.crt")
    set(_stage1_ca_cert_pem_target "${_stage1_ca_target_dir}/cert.pem")
    set(_stage1_ca_stamp_file "${STAGE1_ROOTFS_DIR}/.ca-certificates-installed")
    set(_stage1_ca_depends "${sysroot_stage_dep}")
    if(TARGET stage1-openssl)
      list(APPEND _stage1_ca_depends stage1-openssl)
    endif()

    add_custom_command(
      OUTPUT "${_stage1_ca_stamp_file}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage1_ca_certs_dir}"
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${_stage1_ca_bundle}"
        "${_stage1_ca_bundle_target}"
      COMMAND "${CMAKE_COMMAND}" -E rm -f "${_stage1_ca_cert_pem_target}"
      COMMAND "${CMAKE_COMMAND}" -E create_symlink
        "certs/ca-certificates.crt"
        "${_stage1_ca_cert_pem_target}"
      COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_ca_stamp_file}"
      DEPENDS ${_stage1_ca_depends}
      COMMENT "Installing ca-certificates for ${STAGE1_TARGET_TRIPLE}"
      VERBATIM)

    add_custom_target(stage1-ca-certificates DEPENDS "${_stage1_ca_stamp_file}")
    list(APPEND _stage1_targets stage1-ca-certificates)
  endif()

  set(${out_targets_var} "${_stage1_targets}" PARENT_SCOPE)
endfunction()
