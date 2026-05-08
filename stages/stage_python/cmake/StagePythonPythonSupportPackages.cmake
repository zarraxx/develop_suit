include_guard(GLOBAL)

set(STAGE_PYTHON_LIBFFI_ARCHIVE "" CACHE FILEPATH "Path to the libffi source archive")
set(STAGE_PYTHON_UTIL_LINUX_ARCHIVE "" CACHE FILEPATH "Path to the util-linux source archive used for libuuid")
set(STAGE_PYTHON_LIBEXPAT_ARCHIVE "" CACHE FILEPATH "Path to the libexpat source archive")
set(STAGE_PYTHON_SQLITE_ARCHIVE "" CACHE FILEPATH "Path to the sqlite source archive")
set(STAGE_PYTHON_GDBM_ARCHIVE "" CACHE FILEPATH "Path to the gdbm source archive")
set(STAGE_PYTHON_LIBICONV_ARCHIVE "" CACHE FILEPATH "Path to the libiconv source archive")
set(STAGE_PYTHON_LIBXML2_ARCHIVE "" CACHE FILEPATH "Path to the libxml2 source archive")
set(STAGE_PYTHON_LIBXSLT_ARCHIVE "" CACHE FILEPATH "Path to the libxslt source archive")

set(STAGE_PYTHON_LIBFFI_SOURCE_DIR "" CACHE PATH "Direct path to the libffi source tree")
set(STAGE_PYTHON_UTIL_LINUX_SOURCE_DIR "" CACHE PATH "Direct path to the util-linux source tree")
set(STAGE_PYTHON_LIBEXPAT_SOURCE_DIR "" CACHE PATH "Direct path to the libexpat source tree")
set(STAGE_PYTHON_SQLITE_SOURCE_DIR "" CACHE PATH "Direct path to the sqlite source tree")
set(STAGE_PYTHON_GDBM_SOURCE_DIR "" CACHE PATH "Direct path to the gdbm source tree")
set(STAGE_PYTHON_LIBICONV_SOURCE_DIR "" CACHE PATH "Direct path to the libiconv source tree")
set(STAGE_PYTHON_LIBXML2_SOURCE_DIR "" CACHE PATH "Direct path to the libxml2 source tree")
set(STAGE_PYTHON_LIBXSLT_SOURCE_DIR "" CACHE PATH "Direct path to the libxslt source tree")

set(STAGE_PYTHON_LIBFFI_URL
  "https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz"
  CACHE STRING
  "Download URL for libffi")
set(STAGE_PYTHON_UTIL_LINUX_URL
  "https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.tar.xz"
  CACHE STRING
  "Download URL for util-linux")
set(STAGE_PYTHON_LIBEXPAT_URL
  "https://github.com/libexpat/libexpat/releases/download/R_2_8_0/expat-2.8.0.tar.xz"
  CACHE STRING
  "Download URL for libexpat")
set(STAGE_PYTHON_SQLITE_URL
  "https://sqlite.org/2026/sqlite-autoconf-3530000.tar.gz"
  CACHE STRING
  "Download URL for sqlite")
set(STAGE_PYTHON_GDBM_URL
  "https://ftp.gnu.org/gnu/gdbm/gdbm-1.26.tar.gz"
  CACHE STRING
  "Download URL for gdbm")
set(STAGE_PYTHON_LIBICONV_URL
  "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.19.tar.gz"
  CACHE STRING
  "Download URL for libiconv")
set(STAGE_PYTHON_LIBXML2_URL
  "https://gitlab.gnome.org/GNOME/libxml2/-/archive/v2.15.3/libxml2-v2.15.3.tar.bz2"
  CACHE STRING
  "Download URL for libxml2")
set(STAGE_PYTHON_LIBXSLT_URL
  "https://gitlab.gnome.org/GNOME/libxslt/-/archive/v1.1.45/libxslt-v1.1.45.tar.bz2"
  CACHE STRING
  "Download URL for libxslt")

option(STAGE_PYTHON_ENABLE_PYTHON_SUPPORT_PACKAGES "Build common Python support libraries in stage_python" ON)
option(STAGE_PYTHON_ENABLE_LIBFFI "Enable libffi in stage_python" ON)
option(STAGE_PYTHON_ENABLE_UUID "Enable libuuid in stage_python" ON)
option(STAGE_PYTHON_ENABLE_LIBEXPAT "Enable libexpat in stage_python" ON)
option(STAGE_PYTHON_ENABLE_SQLITE "Enable sqlite in stage_python" ON)
option(STAGE_PYTHON_ENABLE_GDBM "Enable gdbm in stage_python" ON)
option(STAGE_PYTHON_ENABLE_LIBICONV "Enable libiconv in stage_python" ON)
option(STAGE_PYTHON_ENABLE_LIBXML2 "Enable libxml2 in stage_python" ON)
option(STAGE_PYTHON_ENABLE_LIBXSLT "Enable libxslt in stage_python" ON)

set(STAGE_PYTHON_CMAKE_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(stage_python_register_python_support_packages out_var sysroot_stage_dep)
  if(NOT STAGE_PYTHON_ENABLE_PYTHON_SUPPORT_PACKAGES)
    set(${out_var} "" PARENT_SCOPE)
    return()
  endif()

  file(MAKE_DIRECTORY "${STAGE_PYTHON_SOURCE_DIR}")

  set(_stage_python_any_enabled FALSE)
  foreach(_stage_python_opt IN ITEMS
      STAGE_PYTHON_ENABLE_LIBFFI
      STAGE_PYTHON_ENABLE_UUID
      STAGE_PYTHON_ENABLE_LIBEXPAT
      STAGE_PYTHON_ENABLE_SQLITE
      STAGE_PYTHON_ENABLE_GDBM
      STAGE_PYTHON_ENABLE_LIBICONV
      STAGE_PYTHON_ENABLE_LIBXML2
      STAGE_PYTHON_ENABLE_LIBXSLT)
    if(${_stage_python_opt})
      set(_stage_python_any_enabled TRUE)
      break()
    endif()
  endforeach()

  if(NOT _stage_python_any_enabled)
    set(${out_var} "" PARENT_SCOPE)
    return()
  endif()

  find_program(STAGE_PYTHON_HOST_PKG_CONFIG NAMES pkgconf pkg-config REQUIRED)

  set(_stage_python_targets "")
  set(_stage_python_pkg_config_libdir
    "${STAGE_PYTHON_PREFIX_ROOT}/lib/pkgconfig:${STAGE_PYTHON_PREFIX_ROOT}/lib/${STAGE_PYTHON_TARGET_TRIPLE}/pkgconfig:${STAGE_PYTHON_PREFIX_ROOT}/share/pkgconfig")
  set(_stage_python_pkg_config_env
    "PKG_CONFIG=${STAGE_PYTHON_HOST_PKG_CONFIG}"
    "PKG_CONFIG_LIBDIR=${_stage_python_pkg_config_libdir}"
    "PKG_CONFIG_PATH="
    "PKG_CONFIG_SYSROOT_DIR=${STAGE_PYTHON_ROOTFS_DIR}")
  set(_stage_python_dep_cppflags "-I${STAGE_PYTHON_PREFIX_ROOT}/include")
  set(_stage_python_dep_ldflags
    "-L${STAGE_PYTHON_PREFIX_ROOT}/lib -L${STAGE_PYTHON_PREFIX_ROOT}/lib/${STAGE_PYTHON_TARGET_TRIPLE} -L${STAGE_PYTHON_TARGET_RUNTIME_LIBDIR}")

  if(STAGE_PYTHON_ENABLE_LIBFFI)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_LIBFFI_SOURCE_DIR
      "libffi"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/libffi"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_LIBFFI_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_LIBFFI_ARCHIVE}"
      DEFAULT_ARCHIVE "libffi-3.5.2.tar.gz"
      URL "${STAGE_PYTHON_LIBFFI_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/libffi-*.tar.gz")
    stage_python_add_autotools_package(
      stage-python-libffi
      PACKAGE_NAME "libffi"
      SOURCE_DIR "${STAGE_PYTHON_LIBFFI_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${STAGE_PYTHON_NO_DOC_INSTALL_COMMANDS}
      CONFIGURE_ARGS
        "--enable-shared"
        "--enable-static"
        "--disable-dependency-tracking")
    list(APPEND _stage_python_targets stage-python-libffi)
  endif()

  if(STAGE_PYTHON_ENABLE_UUID)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_UTIL_LINUX_SOURCE_DIR
      "util-linux"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/util-linux"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_UTIL_LINUX_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_UTIL_LINUX_ARCHIVE}"
      DEFAULT_ARCHIVE "util-linux-2.42.tar.xz"
      URL "${STAGE_PYTHON_UTIL_LINUX_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/util-linux-*.tar.xz"
        "${STAGE_PYTHON_CACHE_DIR}/util-linux-*.tar.gz")
    stage_python_add_autotools_package(
      stage-python-uuid
      PACKAGE_NAME "uuid"
      SOURCE_DIR "${STAGE_PYTHON_UTIL_LINUX_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${STAGE_PYTHON_NO_DOC_INSTALL_COMMANDS}
      CONFIGURE_ARGS
        "--disable-all-programs"
        "--enable-libuuid"
        "--disable-libblkid"
        "--disable-libmount"
        "--disable-libsmartcols"
        "--disable-nls"
        "--without-python"
        "--without-systemd")
    list(APPEND _stage_python_targets stage-python-uuid)
  endif()

  if(STAGE_PYTHON_ENABLE_LIBEXPAT)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_LIBEXPAT_SOURCE_DIR
      "libexpat"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/libexpat"
      "CMakeLists.txt"
      SOURCE_DIR "${STAGE_PYTHON_LIBEXPAT_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_LIBEXPAT_ARCHIVE}"
      DEFAULT_ARCHIVE "expat-2.8.0.tar.xz"
      URL "${STAGE_PYTHON_LIBEXPAT_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/expat-*.tar.xz"
        "${STAGE_PYTHON_CACHE_DIR}/expat-*.tar.gz")
    stage_python_add_cmake_package(
      stage-python-libexpat
      PACKAGE_NAME "libexpat"
      SOURCE_DIR "${STAGE_PYTHON_LIBEXPAT_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      CMAKE_ARGS
        "-DEXPAT_SHARED_LIBS=ON"
        "-DEXPAT_BUILD_TOOLS=ON"
        "-DEXPAT_BUILD_EXAMPLES=OFF"
        "-DEXPAT_BUILD_TESTS=OFF"
        "-DEXPAT_BUILD_DOCS=OFF")
    list(APPEND _stage_python_targets stage-python-libexpat)
  endif()

  if(STAGE_PYTHON_ENABLE_SQLITE)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_SQLITE_SOURCE_DIR
      "sqlite"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/sqlite"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_SQLITE_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_SQLITE_ARCHIVE}"
      DEFAULT_ARCHIVE "sqlite-autoconf-3530000.tar.gz"
      URL "${STAGE_PYTHON_SQLITE_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/sqlite-autoconf-*.tar.gz")
    stage_python_add_autotools_package(
      stage-python-sqlite
      PACKAGE_NAME "sqlite"
      SOURCE_DIR "${STAGE_PYTHON_SQLITE_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${STAGE_PYTHON_NO_DOC_INSTALL_COMMANDS}
      CONFIGURE_ARGS
        "--enable-shared"
        "--enable-static"
        "--disable-readline")
    list(APPEND _stage_python_targets stage-python-sqlite)
  endif()

  if(STAGE_PYTHON_ENABLE_GDBM)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_GDBM_SOURCE_DIR
      "gdbm"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/gdbm"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_GDBM_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_GDBM_ARCHIVE}"
      DEFAULT_ARCHIVE "gdbm-1.26.tar.gz"
      URL "${STAGE_PYTHON_GDBM_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/gdbm-*.tar.gz"
        "${STAGE_PYTHON_CACHE_DIR}/gdbm-*.tar.xz")
    stage_python_add_autotools_package(
      stage-python-gdbm
      PACKAGE_NAME "gdbm"
      SOURCE_DIR "${STAGE_PYTHON_GDBM_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      POST_INSTALL_COMMANDS
        ${STAGE_PYTHON_NO_DOC_INSTALL_COMMANDS}
      CONFIGURE_ARGS
        "--enable-libgdbm-compat"
        "--enable-shared"
        "--enable-static"
        "--disable-nls"
        "--disable-dependency-tracking")
    list(APPEND _stage_python_targets stage-python-gdbm)
  endif()

  if(STAGE_PYTHON_ENABLE_LIBICONV)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_LIBICONV_SOURCE_DIR
      "libiconv"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/libiconv"
      "configure"
      SOURCE_DIR "${STAGE_PYTHON_LIBICONV_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_LIBICONV_ARCHIVE}"
      DEFAULT_ARCHIVE "libiconv-1.19.tar.gz"
      URL "${STAGE_PYTHON_LIBICONV_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/libiconv-*.tar.gz")
    set(_stage_python_libiconv_post_configure_commands "")
    if(STAGE_PYTHON_TARGET_ARCH STREQUAL "loongarch64")
      list(APPEND _stage_python_libiconv_post_configure_commands
        COMMAND "${CMAKE_COMMAND}"
          "-DINPUT=${STAGE_PYTHON_LIBICONV_SOURCE_DIR}/config.h"
          -P "${STAGE_PYTHON_CMAKE_MODULE_DIR}/StagePythonPatchLibiconvConfig.cmake")
    endif()
    stage_python_add_autotools_package(
      stage-python-libiconv
      PACKAGE_NAME "libiconv"
      SOURCE_DIR "${STAGE_PYTHON_LIBICONV_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      BUILD_IN_SOURCE
      DEPENDS "${sysroot_stage_dep}"
      POST_CONFIGURE_COMMANDS
        ${_stage_python_libiconv_post_configure_commands}
      POST_INSTALL_COMMANDS
        ${STAGE_PYTHON_NO_DOC_INSTALL_COMMANDS}
      CONFIGURE_ARGS
        "--enable-shared"
        "--enable-static")
    list(APPEND _stage_python_targets stage-python-libiconv)
  endif()

  if(STAGE_PYTHON_ENABLE_LIBXML2)
    stage_python_resolve_archive_source(
      STAGE_PYTHON_LIBXML2_SOURCE_DIR
      "libxml2"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/libxml2"
      "CMakeLists.txt"
      SOURCE_DIR "${STAGE_PYTHON_LIBXML2_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_LIBXML2_ARCHIVE}"
      DEFAULT_ARCHIVE "libxml2-v2.15.3.tar.bz2"
      URL "${STAGE_PYTHON_LIBXML2_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/libxml2-*.tar.bz2"
        "${STAGE_PYTHON_CACHE_DIR}/libxml2-*.tar.gz")
    stage_python_add_cmake_package(
      stage-python-libxml2
      PACKAGE_NAME "libxml2"
      SOURCE_DIR "${STAGE_PYTHON_LIBXML2_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS "${sysroot_stage_dep}"
      ENV
        ${_stage_python_pkg_config_env}
      CMAKE_ARGS
        "-DCMAKE_PREFIX_PATH=${STAGE_PYTHON_PREFIX_ROOT}"
        "-DPKG_CONFIG_EXECUTABLE=${STAGE_PYTHON_HOST_PKG_CONFIG}"
        "-DBUILD_SHARED_LIBS=ON"
        "-DLIBXML2_WITH_ICONV=OFF"
        "-DLIBXML2_WITH_ICU=OFF"
        "-DLIBXML2_WITH_PYTHON=OFF"
        "-DLIBXML2_WITH_TESTS=OFF"
        "-DLIBXML2_WITH_PROGRAMS=OFF"
        "-DLIBXML2_WITH_ZLIB=ON")
    list(APPEND _stage_python_targets stage-python-libxml2)
  endif()

  if(STAGE_PYTHON_ENABLE_LIBXSLT)
    set(_stage_python_libxslt_deps "${sysroot_stage_dep}")
    if(TARGET stage-python-libxml2)
      list(APPEND _stage_python_libxslt_deps stage-python-libxml2)
    endif()

    stage_python_resolve_archive_source(
      STAGE_PYTHON_LIBXSLT_SOURCE_DIR
      "libxslt"
      "${STAGE_PYTHON_CACHE_DIR}"
      "${STAGE_PYTHON_SOURCE_DIR}/libxslt"
      "CMakeLists.txt"
      SOURCE_DIR "${STAGE_PYTHON_LIBXSLT_SOURCE_DIR}"
      ARCHIVE "${STAGE_PYTHON_LIBXSLT_ARCHIVE}"
      DEFAULT_ARCHIVE "libxslt-v1.1.45.tar.bz2"
      URL "${STAGE_PYTHON_LIBXSLT_URL}"
      GLOB_PATTERNS
        "${STAGE_PYTHON_CACHE_DIR}/libxslt-*.tar.bz2"
        "${STAGE_PYTHON_CACHE_DIR}/libxslt-*.tar.gz")
    stage_python_add_cmake_package(
      stage-python-libxslt
      PACKAGE_NAME "libxslt"
      SOURCE_DIR "${STAGE_PYTHON_LIBXSLT_SOURCE_DIR}"
      INSTALL_PREFIX "${STAGE_PYTHON_INSTALL_PREFIX}"
      DEPENDS ${_stage_python_libxslt_deps}
      ENV
        ${_stage_python_pkg_config_env}
      CMAKE_ARGS
        "-DCMAKE_PREFIX_PATH=${STAGE_PYTHON_PREFIX_ROOT}"
        "-DPKG_CONFIG_EXECUTABLE=${STAGE_PYTHON_HOST_PKG_CONFIG}"
        "-DBUILD_SHARED_LIBS=ON"
        "-DLIBXSLT_WITH_CRYPTO=OFF"
        "-DLIBXSLT_WITH_DEBUGGER=OFF"
        "-DLIBXSLT_WITH_PROGRAMS=OFF"
        "-DLIBXSLT_WITH_PYTHON=OFF"
        "-DLIBXSLT_WITH_TESTS=OFF"
        "-DLibXml2_DIR=${STAGE_PYTHON_PREFIX_ROOT}/lib/cmake/libxml2")
    list(APPEND _stage_python_targets stage-python-libxslt)
  endif()

  set(${out_var} "${_stage_python_targets}" PARENT_SCOPE)
endfunction()
