include_guard(GLOBAL)

set(STAGE1_NCURSES_ARCHIVE "" CACHE FILEPATH "Path to the ncurses source archive")
set(STAGE1_READLINE_ARCHIVE "" CACHE FILEPATH "Path to the readline source archive")

set(STAGE1_NCURSES_SOURCE_DIR "" CACHE PATH "Direct path to the ncurses source tree")
set(STAGE1_READLINE_SOURCE_DIR "" CACHE PATH "Direct path to the readline source tree")

set(STAGE1_NCURSES_URL
  "https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz"
  CACHE STRING
  "Download URL for ncurses")
set(STAGE1_READLINE_URL
  "https://ftp.gnu.org/gnu/readline/readline-8.3.tar.gz"
  CACHE STRING
  "Download URL for readline")

option(STAGE1_ENABLE_TERMINAL_PACKAGES "Build terminal libraries in stage1" ON)
option(STAGE1_ENABLE_NCURSES "Build ncurses in stage1" ON)
option(STAGE1_ENABLE_READLINE "Build readline in stage1" ON)

set(STAGE1_TERMINAL_PACKAGE_NAMES
  ncurses
  readline)

function(stage1_register_terminal_packages out_targets_var sysroot_stage_dep)
  if(NOT STAGE1_ENABLE_TERMINAL_PACKAGES)
    set(${out_targets_var} "" PARENT_SCOPE)
    return()
  endif()

  find_program(STAGE1_SED_PROGRAM NAMES sed REQUIRED)

  if(STAGE1_ENABLE_NCURSES OR STAGE1_ENABLE_READLINE)
    stage1_resolve_archive_source(
      STAGE1_NCURSES_SOURCE_DIR
      "ncurses"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/ncurses"
      "configure"
      SOURCE_DIR "${STAGE1_NCURSES_SOURCE_DIR}"
      ARCHIVE "${STAGE1_NCURSES_ARCHIVE}"
      DEFAULT_ARCHIVE "ncurses-6.6.tar.gz"
      URL "${STAGE1_NCURSES_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/ncurses-*.tar.gz")
  endif()

  if(STAGE1_ENABLE_READLINE)
    stage1_resolve_archive_source(
      STAGE1_READLINE_SOURCE_DIR
      "readline"
      "${STAGE1_CACHE_DIR}"
      "${STAGE1_SOURCE_DIR}/readline"
      "configure"
      SOURCE_DIR "${STAGE1_READLINE_SOURCE_DIR}"
      ARCHIVE "${STAGE1_READLINE_ARCHIVE}"
      DEFAULT_ARCHIVE "readline-8.3.tar.gz"
      URL "${STAGE1_READLINE_URL}"
      GLOB_PATTERNS
        "${STAGE1_CACHE_DIR}/readline-*.tar.gz")
  endif()

  set(_stage1_targets "")
  set(_stage1_prefix_root "${STAGE1_ROOTFS_DIR}${STAGE1_INSTALL_PREFIX}")
  set(_stage1_pkgconfig_dir "${STAGE1_INSTALL_PREFIX}/lib/pkgconfig")
  set(_stage1_readline_build_triple "${STAGE1_BUILD_TRIPLE}")
  if(STAGE1_TARGET_TRIPLE STREQUAL STAGE1_BUILD_TRIPLE)
    string(REGEX REPLACE "^([^-]+)-([^-]+)-(.*)$" "\\1-stage1build-\\3"
      _stage1_readline_build_triple
      "${STAGE1_BUILD_TRIPLE}")
  endif()
  stage1_get_lib_only_install_commands("${STAGE1_ROOTFS_DIR}" "${STAGE1_INSTALL_PREFIX}" _stage1_lib_only_install_commands)

  if(STAGE1_ENABLE_NCURSES)
    stage1_add_configure_make_package(
      stage1-ncurses
      PACKAGE_NAME "ncurses"
      SOURCE_DIR "${STAGE1_NCURSES_SOURCE_DIR}"
      CONFIGURE_PATH "${STAGE1_NCURSES_SOURCE_DIR}/configure"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      CONFIGURE_ARGS
        --with-shared
        --disable-static
        --without-profile
        --without-debug
        --without-cxx
        --without-cxx-binding
        --without-ada
        --without-manpages
        --without-tests
        --without-progs
        --enable-echo
        --enable-const
        --enable-widec
        --with-termlib
        --disable-termcap
        --enable-pc-files
        --with-pkg-config-libdir=${_stage1_pkgconfig_dir}
      POST_INSTALL_COMMANDS
        COMMAND "${CMAKE_COMMAND}" -E rm -f
          "${_stage1_prefix_root}/lib/pkgconfig/termcap.pc"
        COMMAND "${CMAKE_COMMAND}" -E create_symlink
          "ncursesw.pc"
          "${_stage1_prefix_root}/lib/pkgconfig/termcap.pc"
        ${_stage1_lib_only_install_commands}
      DEPENDS "${sysroot_stage_dep}")
    list(APPEND _stage1_targets stage1-ncurses)
  endif()

  if(STAGE1_ENABLE_READLINE)
    stage1_add_configure_make_package(
      stage1-readline
      PACKAGE_NAME "readline"
      SOURCE_DIR "${STAGE1_READLINE_SOURCE_DIR}"
      CONFIGURE_PATH "${STAGE1_READLINE_SOURCE_DIR}/configure"
      INSTALL_PREFIX "${STAGE1_INSTALL_PREFIX}"
      BUILD_TRIPLE "${_stage1_readline_build_triple}"
      CONFIGURE_ARGS
        --enable-shared=yes
        --enable-static=no
        --disable-install-examples
      ENV
        "CFLAGS=-I${_stage1_prefix_root}/include -I${_stage1_prefix_root}/include/ncursesw"
        "LDFLAGS=-L${_stage1_prefix_root}/lib -lncursesw -ltinfow"
        "SHLIB_LIBS=-lncursesw -ltinfow"
      POST_INSTALL_COMMANDS
        COMMAND "${CMAKE_COMMAND}" -E rm -rf
          "${_stage1_prefix_root}/share/readline"
        COMMAND "${STAGE1_SED_PROGRAM}" -i
          "s|-lreadline|-lreadline -lncursesw -ltinfow |g"
          "${_stage1_prefix_root}/lib/pkgconfig/readline.pc"
        ${_stage1_lib_only_install_commands}
      DEPENDS
        "${sysroot_stage_dep}"
        stage1-ncurses)
    list(APPEND _stage1_targets stage1-readline)
  endif()

  set(${out_targets_var} "${_stage1_targets}" PARENT_SCOPE)
endfunction()
