include_guard(GLOBAL)

set(STAGE1_SCRIPTING_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

set(STAGE1_PERL_ARCHIVE "" CACHE FILEPATH "Path to the Perl source archive")
set(STAGE1_PERL_SOURCE_DIR "" CACHE PATH "Direct path to the Perl source tree")
set(STAGE1_PERL_URL
  "https://cpan.metacpan.org/authors/id/S/SH/SHAY/perl-5.42.2.tar.gz"
  CACHE STRING
  "Download URL for Perl")

set(STAGE1_PERL_LOCAL_TARGETHOST "localhost" CACHE STRING
  "Synthetic target host name used by Perl's cross-compilation flow")
set(STAGE1_PERL_LOCAL_TARGETUSER "stage1" CACHE STRING
  "Synthetic target user name used by Perl's cross-compilation flow")
set(STAGE1_PERL_LOCAL_TARGETPORT "22" CACHE STRING
  "Synthetic target port used by Perl's cross-compilation flow")
set(STAGE1_PERL_LOCAL_SSH_SHELL "/bin/sh" CACHE FILEPATH
  "Shell used by the generated local ssh wrapper for Perl")
set(STAGE1_PERL_LOCAL_SSH_PRELUDE "" CACHE STRING
  "Optional shell prelude injected before Perl cross-run commands; useful when foreign target binaries rely on binfmt/qemu setup")
set(STAGE1_PERL_LOCAL_QEMU_LD_PREFIX "" CACHE PATH
  "Override QEMU_LD_PREFIX used by Perl's local cross transport; defaults to the staged stage1 rootfs for foreign targets")

option(STAGE1_ENABLE_SCRIPTING_PACKAGES "Build scripting language packages in stage1" ON)
option(STAGE1_ENABLE_PERL "Build Perl in stage1" ON)

set(STAGE1_SCRIPTING_PACKAGE_NAMES
  perl)

function(stage1_perl_targetarch_from_target_triple input_triple out_var)
  if(input_triple MATCHES "^x86_64-.*-linux-gnu$")
    set(_targetarch "x86_64-linux")
  elseif(input_triple MATCHES "^aarch64-.*-linux-gnu$")
    set(_targetarch "aarch64-linux")
  elseif(input_triple MATCHES "^riscv64-.*-linux-gnu$")
    set(_targetarch "riscv64-linux")
  elseif(input_triple MATCHES "^loongarch64-.*-linux-gnu$")
    set(_targetarch "loongarch64-linux")
  else()
    message(FATAL_ERROR "Unsupported Perl target triple: ${input_triple}")
  endif()

  set(${out_var} "${_targetarch}" PARENT_SCOPE)
endfunction()

function(stage1_perl_build_env out_var)
  set(_env
    "TMPDIR=${STAGE1_TMP_DIR}"
    "TMP=${STAGE1_TMP_DIR}"
    "TEMP=${STAGE1_TMP_DIR}"
    "TEMPDIR=${STAGE1_TMP_DIR}"
    "PERL=${STAGE1_HOST_PERL}"
    "HASHBANGPERL=/usr/bin/perl"
    "CC_FOR_BUILD=${STAGE1_HOST_CC}"
    "CXX_FOR_BUILD=${STAGE1_HOST_CXX}"
    "CPP_FOR_BUILD=${STAGE1_HOST_CC} -E")
  set(${out_var} "${_env}" PARENT_SCOPE)
endfunction()

function(stage1_perl_prepare_local_transport package_build_dir out_env_var out_args_var)
  set(_transport_dir "${STAGE1_TOOLCHAIN_DIR}/perl-transport")
  set(_target_run_dir "${package_build_dir}/target-run")
  set(_ssh_wrapper "${_transport_dir}/ssh")

  file(MAKE_DIRECTORY "${_transport_dir}")

  set(_qemu_ld_prefix "")
  if(STAGE1_TARGET_TRIPLE STREQUAL STAGE1_BUILD_TRIPLE)
    set(_qemu_ld_prefix "${STAGE1_PERL_LOCAL_QEMU_LD_PREFIX}")
  else()
    if(STAGE1_PERL_LOCAL_QEMU_LD_PREFIX STREQUAL "")
      set(_qemu_ld_prefix "${STAGE1_ROOTFS_DIR}")
    else()
      set(_qemu_ld_prefix "${STAGE1_PERL_LOCAL_QEMU_LD_PREFIX}")
    endif()
  endif()

  set(STAGE1_PERL_LOCAL_SSH_WRAPPER_QEMU_LD_PREFIX "${_qemu_ld_prefix}")
  set(STAGE1_PERL_LOCAL_SSH_WRAPPER_PRELUDE "${STAGE1_PERL_LOCAL_SSH_PRELUDE}")
  set(STAGE1_PERL_LOCAL_SSH_WRAPPER_SHELL "${STAGE1_PERL_LOCAL_SSH_SHELL}")
  configure_file(
    "${STAGE1_SCRIPTING_MODULE_DIR}/perl-cross-local-ssh.sh.in"
    "${_ssh_wrapper}"
    @ONLY)
  file(CHMOD
    "${_ssh_wrapper}"
    PERMISSIONS
      OWNER_READ OWNER_WRITE OWNER_EXECUTE
      GROUP_READ GROUP_EXECUTE
      WORLD_READ WORLD_EXECUTE)

  set(_env
    "PATH=${_transport_dir}:${STAGE1_LLVM_BIN_DIR}:$ENV{PATH}")
  set(_args
    "-Dtargethost=${STAGE1_PERL_LOCAL_TARGETHOST}"
    "-Dtargetuser=${STAGE1_PERL_LOCAL_TARGETUSER}"
    "-Dtargetport=${STAGE1_PERL_LOCAL_TARGETPORT}"
    "-Dtargetrun=ssh"
    "-Dtargetto=cp"
    "-Dtargetfrom=cp"
    "-Dtargetdir=${_target_run_dir}")

  if(NOT STAGE1_TARGET_TRIPLE STREQUAL STAGE1_BUILD_TRIPLE)
    message(WARNING
      "Perl for ${STAGE1_TARGET_TRIPLE} will use the local cross transport.\n"
      "This requires target binaries to be runnable on the build host, typically via "
      "binfmt_misc/qemu-user or equivalent emulation.\n"
      "QEMU_LD_PREFIX will default to ${_qemu_ld_prefix}.")
  endif()

  set(${out_env_var} "${_env}" PARENT_SCOPE)
  set(${out_args_var} "${_args}" PARENT_SCOPE)
endfunction()

function(stage1_register_scripting_packages out_targets_var sysroot_stage_dep)
  if(NOT STAGE1_ENABLE_SCRIPTING_PACKAGES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  if(NOT STAGE1_ENABLE_PERL)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  find_program(STAGE1_HOST_PERL NAMES perl REQUIRED)
  find_program(STAGE1_MAKE_PROGRAM NAMES gmake make REQUIRED)

  stage1_resolve_archive_source(
    STAGE1_PERL_SOURCE_DIR
    "Perl"
    "${STAGE1_CACHE_DIR}"
    "${STAGE1_SOURCE_DIR}/perl"
    "Configure"
    SOURCE_DIR "${STAGE1_PERL_SOURCE_DIR}"
    ARCHIVE "${STAGE1_PERL_ARCHIVE}"
    DEFAULT_ARCHIVE "perl-5.42.2.tar.gz"
    URL "${STAGE1_PERL_URL}"
    GLOB_PATTERNS
      "${STAGE1_CACHE_DIR}/perl-*.tar.gz")

  stage1_perl_targetarch_from_target_triple("${STAGE1_TARGET_TRIPLE}" _stage1_perl_targetarch)

  set(_stage1_targets "")
  set(_stage1_package_build_dir "${STAGE1_PACKAGE_BUILD_ROOT}/perl")
  set(_stage1_stamp_file "${STAGE1_ROOTFS_DIR}/.perl-installed")

  stage1_perl_build_env(_stage1_perl_common_env)
  stage1_perl_prepare_local_transport(
    "${_stage1_package_build_dir}"
    _stage1_perl_transport_env
    _stage1_perl_transport_args)
  stage1_get_no_doc_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_no_doc_install_commands)

  set(_stage1_perl_env
    ${_stage1_perl_common_env}
    ${_stage1_perl_transport_env})
  set(_stage1_configure_args
    -des
    -Dusecrosscompile
    -Duseshrplib
    -Dprefix=${STAGE1_INSTALL_PREFIX}
    -Dcc=${STAGE1_TARGET_CC_WRAPPER}
    -Dld=${STAGE1_TARGET_CC_WRAPPER}
    -Dar=${STAGE1_LLVM_BIN_DIR}/llvm-ar
    -Dnm=${STAGE1_LLVM_BIN_DIR}/llvm-nm
    -Dranlib=${STAGE1_LLVM_BIN_DIR}/llvm-ranlib
    -Dtargetarch=${_stage1_perl_targetarch}
    -Dsysroot=${STAGE1_ROOTFS_DIR}
    -Dusrinc=/usr/include
    -Dincpth=/usr/include
    "-Dlibpth=/lib /usr/lib /usr/lib/${STAGE1_TARGET_TRIPLE}"
    -Ulocincpth
    -Uloclibpth
    ${_stage1_perl_transport_args})

  add_custom_command(
    OUTPUT "${_stage1_stamp_file}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_stage1_package_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${STAGE1_PERL_SOURCE_DIR}" "${_stage1_package_build_dir}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_stage1_package_build_dir}/target-run"
    COMMAND "${STAGE1_HOST_PERL}" -0pi -e
      "s/&& \\.\\/try; then/&& \\$run .\\/try; then/g; s/if eval \\$compile && \\.\\/try; then/if eval \\$compile && \\$run .\\/try; then/g"
      "${_stage1_package_build_dir}/Configure"
    COMMAND "${CMAKE_COMMAND}" -E chdir "${_stage1_package_build_dir}"
      "${CMAKE_COMMAND}" -E env
      ${_stage1_perl_env}
      /bin/sh ./Configure
      ${_stage1_configure_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage1_perl_env}
      "${STAGE1_MAKE_PROGRAM}"
      -C "${_stage1_package_build_dir}"
      "-j${STAGE1_JOBS}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage1_perl_env}
      "${STAGE1_MAKE_PROGRAM}"
      -C "${_stage1_package_build_dir}"
      "DESTDIR=${STAGE1_ROOTFS_DIR}"
      install
    ${_stage1_no_doc_install_commands}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_stage1_stamp_file}"
    DEPENDS "${sysroot_stage_dep}"
    COMMENT "Building Perl for ${STAGE1_TARGET_TRIPLE}"
    VERBATIM)

  add_custom_target(stage1-perl DEPENDS "${_stage1_stamp_file}")
  list(APPEND _stage1_targets stage1-perl)

  set(${out_targets_var} "${_stage1_targets}" PARENT_SCOPE)
endfunction()
