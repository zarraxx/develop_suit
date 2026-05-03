cmake_minimum_required(VERSION 3.24)

project(stage0_busybox LANGUAGES NONE)

include(ProcessorCount)

function(stage0_archive_stem input_path out_var)
  get_filename_component(_name "${input_path}" NAME)
  string(REGEX REPLACE "\\.(tar\\.(gz|bz2|xz)|tgz|tbz2|txz)$" "" _stem "${_name}")
  set(${out_var} "${_stem}" PARENT_SCOPE)
endfunction()

function(stage0_normalize_host_arch input_arch out_var)
  string(TOLOWER "${input_arch}" _arch)
  if(_arch STREQUAL "amd64")
    set(_arch "x86_64")
  elseif(_arch STREQUAL "arm64")
    set(_arch "aarch64")
  endif()
  set(${out_var} "${_arch}" PARENT_SCOPE)
endfunction()

function(stage0_pick_single_file out_var description)
  stage0_try_pick_single_file(${out_var} "${description}" ${ARGN})
  if("${${out_var}}" STREQUAL "")
    message(FATAL_ERROR "Could not find ${description}. Looked for: ${ARGN}")
  endif()
endfunction()

function(stage0_try_pick_single_file out_var description)
  set(_matches "")
  foreach(_pattern IN LISTS ARGN)
    file(GLOB _pattern_matches LIST_DIRECTORIES FALSE "${_pattern}")
    list(APPEND _matches ${_pattern_matches})
  endforeach()
  list(REMOVE_DUPLICATES _matches)
  list(LENGTH _matches _count)
  if(_count EQUAL 0)
    set(${out_var} "" PARENT_SCOPE)
    return()
  elseif(_count GREATER 1)
    message(FATAL_ERROR
      "Found multiple candidates for ${description}: ${_matches}\n"
      "Please pass an explicit path.")
  endif()
  list(GET _matches 0 _match)
  set(${out_var} "${_match}" PARENT_SCOPE)
endfunction()

function(stage0_download_file_once output_path url description)
  if(EXISTS "${output_path}")
    return()
  endif()

  if(url STREQUAL "")
    message(FATAL_ERROR "No download URL configured for ${description}.")
  endif()

  get_filename_component(_output_dir "${output_path}" DIRECTORY)
  set(_tmp_path "${output_path}.tmp")

  file(MAKE_DIRECTORY "${_output_dir}")
  message(STATUS "Downloading ${description}: ${url}")
  file(DOWNLOAD
    "${url}"
    "${_tmp_path}"
    STATUS _download_status
    LOG _download_log
    SHOW_PROGRESS
    TLS_VERIFY ON)

  list(GET _download_status 0 _download_code)
  list(GET _download_status 1 _download_message)
  if(NOT _download_code EQUAL 0)
    file(REMOVE "${_tmp_path}")
    message(FATAL_ERROR
      "Failed to download ${description} from ${url}\n"
      "Status: ${_download_code} (${_download_message})\n"
      "Log:\n${_download_log}")
  endif()

  file(RENAME "${_tmp_path}" "${output_path}")
endfunction()

function(stage0_ensure_default_archive out_var description cache_dir archive_name archive_url)
  set(_archive_path "${cache_dir}/${archive_name}")
  if(NOT EXISTS "${_archive_path}")
    if(NOT STAGE0_DOWNLOAD_MISSING)
      message(FATAL_ERROR
        "Could not find ${description} at ${_archive_path} and automatic download is disabled.\n"
        "Set STAGE0_DOWNLOAD_MISSING=ON, place the archive in cache/, or pass an explicit path.")
    endif()
    stage0_download_file_once("${_archive_path}" "${archive_url}" "${description}")
  endif()
  set(${out_var} "${_archive_path}" PARENT_SCOPE)
endfunction()

function(stage0_default_llvm_download_info out_filename_var out_url_var)
  stage0_normalize_host_arch("${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)
  if(_host_arch STREQUAL "x86_64")
    set(_archive_name "compiler-llvm-18.1.8-linux-x86_64.tar.gz")
    set(_archive_url "${STAGE0_LLVM_X86_64_URL}")
  elseif(_host_arch STREQUAL "aarch64")
    set(_archive_name "compiler-llvm-18.1.8-linux-aarch64.tar.gz")
    set(_archive_url "${STAGE0_LLVM_AARCH64_URL}")
  else()
    message(FATAL_ERROR
      "Automatic LLVM host toolchain download is not configured for host arch "
      "${CMAKE_HOST_SYSTEM_PROCESSOR}. Set STAGE0_LLVM_ARCHIVE or STAGE0_CLANG_ROOT explicitly.")
  endif()

  set(${out_filename_var} "${_archive_name}" PARENT_SCOPE)
  set(${out_url_var} "${_archive_url}" PARENT_SCOPE)
endfunction()

function(stage0_resolve_default_llvm_archive out_var cache_dir)
  stage0_normalize_host_arch("${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)
  file(GLOB _all_archives LIST_DIRECTORIES FALSE "${cache_dir}/compiler-llvm-*-linux-*.tar.gz")
  if(NOT _all_archives)
    stage0_default_llvm_download_info(_default_llvm_name _default_llvm_url)
    stage0_ensure_default_archive(
      _downloaded_llvm_archive
      "LLVM host toolchain archive for ${_host_arch}"
      "${cache_dir}"
      "${_default_llvm_name}"
      "${_default_llvm_url}")
    set(${out_var} "${_downloaded_llvm_archive}" PARENT_SCOPE)
    return()
  endif()

  set(_filtered "")
  foreach(_archive IN LISTS _all_archives)
    if(_archive MATCHES "-linux-${_host_arch}\\.tar\\.gz$")
      list(APPEND _filtered "${_archive}")
    endif()
  endforeach()

  list(LENGTH _filtered _filtered_count)
  if(_filtered_count EQUAL 1)
    list(GET _filtered 0 _selected)
    set(${out_var} "${_selected}" PARENT_SCOPE)
    return()
  endif()

  if(_filtered_count GREATER 1)
    message(FATAL_ERROR
      "Found multiple LLVM archives matching host arch ${_host_arch}: ${_filtered}\n"
      "Please set STAGE0_LLVM_ARCHIVE explicitly.")
  endif()

  stage0_default_llvm_download_info(_default_llvm_name _default_llvm_url)
  set(_expected_default_archive "${cache_dir}/${_default_llvm_name}")
  if(EXISTS "${_expected_default_archive}")
    set(${out_var} "${_expected_default_archive}" PARENT_SCOPE)
    return()
  endif()

  if(STAGE0_DOWNLOAD_MISSING)
    stage0_ensure_default_archive(
      _downloaded_llvm_archive
      "LLVM host toolchain archive for ${_host_arch}"
      "${cache_dir}"
      "${_default_llvm_name}"
      "${_default_llvm_url}")
    set(${out_var} "${_downloaded_llvm_archive}" PARENT_SCOPE)
    return()
  endif()

  message(FATAL_ERROR
    "Found LLVM archives (${_all_archives}) but none matched host arch ${_host_arch}.\n"
    "Set STAGE0_LLVM_ARCHIVE explicitly or enable automatic download.")
endfunction()

function(stage0_extract_archive_once archive_path destination_dir)
  if(NOT EXISTS "${archive_path}")
    message(FATAL_ERROR "Archive does not exist: ${archive_path}")
  endif()

  file(SHA256 "${archive_path}" _archive_hash)
  set(_stamp_path "${destination_dir}/.stage0-extract.sha256")
  set(_needs_extract TRUE)

  if(EXISTS "${_stamp_path}")
    file(READ "${_stamp_path}" _existing_hash)
    string(STRIP "${_existing_hash}" _existing_hash)
    if(_existing_hash STREQUAL "${_archive_hash}")
      set(_needs_extract FALSE)
    endif()
  endif()

  if(_needs_extract)
    file(REMOVE_RECURSE "${destination_dir}")
    file(MAKE_DIRECTORY "${destination_dir}")
    message(STATUS "Extracting ${archive_path} -> ${destination_dir}")
    file(ARCHIVE_EXTRACT INPUT "${archive_path}" DESTINATION "${destination_dir}")
    file(WRITE "${_stamp_path}" "${_archive_hash}\n")
  endif()
endfunction()

function(stage0_unwrap_single_subdir root_dir marker_relpath out_var)
  set(_current_dir "${root_dir}")
  set(_depth 0)

  while(NOT EXISTS "${_current_dir}/${marker_relpath}")
    if(_depth GREATER 8)
      message(FATAL_ERROR
        "Could not find ${marker_relpath} under ${root_dir}. "
        "Stopped at ${_current_dir}.")
    endif()

    file(GLOB _children RELATIVE "${_current_dir}" "${_current_dir}/*")
    set(_subdirs "")
    foreach(_child IN LISTS _children)
      if(IS_DIRECTORY "${_current_dir}/${_child}")
        list(APPEND _subdirs "${_child}")
      endif()
    endforeach()

    list(LENGTH _subdirs _subdir_count)
    if(NOT _subdir_count EQUAL 1)
      message(FATAL_ERROR
        "Could not find ${marker_relpath} under ${root_dir}. "
        "Expected a single nested directory under ${_current_dir}, got: ${_subdirs}")
    endif()

    list(GET _subdirs 0 _next_dir)
    set(_current_dir "${_current_dir}/${_next_dir}")
    math(EXPR _depth "${_depth} + 1")
  endwhile()

  set(${out_var} "${_current_dir}" PARENT_SCOPE)
endfunction()

function(stage0_detect_elf_symbol file_path symbol_name out_var)
  if(NOT EXISTS "${file_path}")
    set(${out_var} FALSE PARENT_SCOPE)
    return()
  endif()

  execute_process(
    COMMAND "${STAGE0_READELF}" -Ws "${file_path}"
    RESULT_VARIABLE _readelf_status
    OUTPUT_VARIABLE _readelf_output
    ERROR_VARIABLE _readelf_error
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE)

  if(NOT _readelf_status EQUAL 0)
    message(WARNING
      "Failed to inspect ELF symbols in ${file_path} with ${STAGE0_READELF}: "
      "${_readelf_error}")
    set(${out_var} FALSE PARENT_SCOPE)
    return()
  endif()

  string(FIND "${_readelf_output}" "${symbol_name}" _symbol_pos)
  if(_symbol_pos EQUAL -1)
    set(${out_var} FALSE PARENT_SCOPE)
  else()
    set(${out_var} TRUE PARENT_SCOPE)
  endif()
endfunction()

set(STAGE0_CACHE_DIR "${CMAKE_CURRENT_LIST_DIR}/../cache" CACHE PATH "Directory containing downloaded archives")
set(STAGE0_WORK_DIR "${CMAKE_BINARY_DIR}/stage0-work" CACHE PATH "Working directory used by the stage0 build")
set(STAGE0_PREBUILD_DIR "${STAGE0_WORK_DIR}/prebuild" CACHE PATH "Extracted toolchains and sysroots")
set(STAGE0_SOURCE_DIR "${STAGE0_WORK_DIR}/src" CACHE PATH "Extracted third-party sources")
set(STAGE0_TMP_DIR "${STAGE0_WORK_DIR}/tmp" CACHE PATH "Temporary directory used by build tools instead of /tmp")
set(STAGE0_OUTPUT_DIR "${CMAKE_BINARY_DIR}/out" CACHE PATH "Build output directory")

set(STAGE0_TARGET_TRIPLE "" CACHE STRING "Target triple for BusyBox, for example x86_64-unknown-linux-gnu")
set(STAGE0_BUSYBOX_CONFIG_TARGET "defconfig" CACHE STRING "BusyBox config target to invoke before building")
set(STAGE0_BUSYBOX_CONFIG_FRAGMENT "${CMAKE_CURRENT_LIST_DIR}/busybox-stage0.configfrag" CACHE FILEPATH "BusyBox config fragment applied after the base config target")
set(STAGE0_BUSYBOX_EXTRA_CFLAGS "" CACHE STRING "Extra target C flags forwarded to BusyBox as EXTRA_CFLAGS")
set(STAGE0_BUSYBOX_EXTRA_LDFLAGS "" CACHE STRING "Extra target linker flags forwarded to BusyBox as EXTRA_LDFLAGS")
set(STAGE0_LLVM_ARCHIVE "" CACHE FILEPATH "Path to the LLVM/Clang archive used on the host")
set(STAGE0_LLVM_SOURCE_ARCHIVE "" CACHE FILEPATH "Path to the llvm-project source archive used to build target runtimes")
set(STAGE0_SYSROOT_ARCHIVE "" CACHE FILEPATH "Path to the sysroot archive containing target sysroots")
set(STAGE0_BUSYBOX_ARCHIVE "" CACHE FILEPATH "Path to the BusyBox source archive")
set(STAGE0_CLANG_ROOT "" CACHE PATH "Pre-extracted clang root containing bin/clang")
set(STAGE0_LLVM_SOURCE_DIR "" CACHE PATH "Direct path to the llvm-project monorepo root containing llvm/ and runtimes/")
set(STAGE0_TARGET_SYSROOT_DIR "" CACHE PATH "Direct path to the target sysroot directory")
set(STAGE0_BUSYBOX_SOURCE_DIR "" CACHE PATH "Direct path to the BusyBox source tree")
set(STAGE0_LLVM_RUNTIME_COMPONENTS "compiler-rt;libcxx;libcxxabi;libunwind" CACHE STRING "Semicolon-separated list of LLVM runtimes built for the target rootfs")
set(STAGE0_LLVM_RUNTIME_BUILD_TYPE "Release" CACHE STRING "Build type used for LLVM runtimes")
set(STAGE0_LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL "AUTO" CACHE STRING "Whether target libc exports __cxa_thread_atexit_impl. Supported values: AUTO, ON, OFF")
set(STAGE0_CXX_RUNTIMES_USE_COMPILER_RT "AUTO" CACHE STRING "Whether libunwind/libcxxabi/libcxx should link against compiler-rt. Supported values: AUTO, ON, OFF")
option(STAGE0_DOWNLOAD_MISSING "Automatically download missing archives into STAGE0_CACHE_DIR during configure" ON)
option(STAGE0_VERBOSE_BUILD "Enable verbose nested build output for LLVM runtimes and BusyBox" OFF)
set(STAGE0_LLVM_SOURCE_URL "https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz" CACHE STRING "Download URL for the llvm-project source archive")
set(STAGE0_SYSROOT_URL "https://github.com/zarraxx/package_builder/releases/download/sysroot-15.2.0/sysroot-15.2.0-linux.tar.xz" CACHE STRING "Download URL for the target sysroot archive")
set(STAGE0_BUSYBOX_URL "https://busybox.net/downloads/busybox-1.37.0.tar.bz2" CACHE STRING "Download URL for the BusyBox source archive")
set(STAGE0_LLVM_X86_64_URL "https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-x86_64.tar.gz" CACHE STRING "Download URL for the x86_64 host LLVM toolchain archive")
set(STAGE0_LLVM_AARCH64_URL "https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-aarch64.tar.gz" CACHE STRING "Download URL for the aarch64 host LLVM toolchain archive")

ProcessorCount(_default_jobs)
if(NOT _default_jobs)
  set(_default_jobs 1)
endif()
set(STAGE0_JOBS "${_default_jobs}" CACHE STRING "Parallel build job count passed to make")

if(STAGE0_TARGET_TRIPLE STREQUAL "")
  message(FATAL_ERROR "STAGE0_TARGET_TRIPLE is required.")
endif()

if(STAGE0_CLANG_ROOT STREQUAL "")
  if(STAGE0_LLVM_ARCHIVE STREQUAL "")
    stage0_resolve_default_llvm_archive(STAGE0_LLVM_ARCHIVE "${STAGE0_CACHE_DIR}")
  endif()
  stage0_archive_stem("${STAGE0_LLVM_ARCHIVE}" _llvm_stem)
  set(_llvm_extract_dir "${STAGE0_PREBUILD_DIR}/llvm/${_llvm_stem}")
  stage0_extract_archive_once("${STAGE0_LLVM_ARCHIVE}" "${_llvm_extract_dir}")
  stage0_unwrap_single_subdir("${_llvm_extract_dir}" "bin/clang" STAGE0_CLANG_ROOT)
endif()

if(STAGE0_TARGET_SYSROOT_DIR STREQUAL "")
  if(STAGE0_SYSROOT_ARCHIVE STREQUAL "")
    stage0_try_pick_single_file(
      _resolved_sysroot_archive
      "sysroot archive"
      "${STAGE0_CACHE_DIR}/sysroot-*.tar.xz"
      "${STAGE0_CACHE_DIR}/sysroot-*.tar.gz"
      "${STAGE0_CACHE_DIR}/sysroot-*.txz")
    if(_resolved_sysroot_archive STREQUAL "")
      stage0_ensure_default_archive(
        _resolved_sysroot_archive
        "sysroot archive"
        "${STAGE0_CACHE_DIR}"
        "sysroot-15.2.0-linux.tar.xz"
        "${STAGE0_SYSROOT_URL}")
    endif()
    set(STAGE0_SYSROOT_ARCHIVE "${_resolved_sysroot_archive}")
  endif()
  stage0_archive_stem("${STAGE0_SYSROOT_ARCHIVE}" _sysroot_stem)
  set(_sysroot_extract_dir "${STAGE0_PREBUILD_DIR}/sysroot/${_sysroot_stem}")
  stage0_extract_archive_once("${STAGE0_SYSROOT_ARCHIVE}" "${_sysroot_extract_dir}")
  stage0_unwrap_single_subdir("${_sysroot_extract_dir}" "${STAGE0_TARGET_TRIPLE}/sysroot" _sysroot_package_root)
  set(STAGE0_TARGET_SYSROOT_DIR "${_sysroot_package_root}/${STAGE0_TARGET_TRIPLE}/sysroot")
endif()

if(STAGE0_BUSYBOX_SOURCE_DIR STREQUAL "")
  if(STAGE0_BUSYBOX_ARCHIVE STREQUAL "")
    stage0_try_pick_single_file(
      _resolved_busybox_archive
      "BusyBox archive"
      "${STAGE0_CACHE_DIR}/busybox-*.tar.bz2"
      "${STAGE0_CACHE_DIR}/busybox-*.tar.gz"
      "${STAGE0_CACHE_DIR}/busybox-*.tar.xz")
    if(_resolved_busybox_archive STREQUAL "")
      stage0_ensure_default_archive(
        _resolved_busybox_archive
        "BusyBox archive"
        "${STAGE0_CACHE_DIR}"
        "busybox-1.37.0.tar.bz2"
        "${STAGE0_BUSYBOX_URL}")
    endif()
    set(STAGE0_BUSYBOX_ARCHIVE "${_resolved_busybox_archive}")
  endif()
  stage0_archive_stem("${STAGE0_BUSYBOX_ARCHIVE}" _busybox_stem)
  set(_busybox_extract_dir "${STAGE0_SOURCE_DIR}/busybox/${_busybox_stem}")
  stage0_extract_archive_once("${STAGE0_BUSYBOX_ARCHIVE}" "${_busybox_extract_dir}")
  stage0_unwrap_single_subdir("${_busybox_extract_dir}" "Makefile" STAGE0_BUSYBOX_SOURCE_DIR)
endif()

if(STAGE0_LLVM_SOURCE_DIR STREQUAL "")
  if(STAGE0_LLVM_SOURCE_ARCHIVE STREQUAL "")
    stage0_try_pick_single_file(
      _resolved_llvm_source_archive
      "llvm-project source archive"
      "${STAGE0_CACHE_DIR}/llvm-project-*.src.tar.xz"
      "${STAGE0_CACHE_DIR}/llvm-project-*.src.tar.gz"
      "${STAGE0_CACHE_DIR}/llvm-project-*.tar.xz")
    if(_resolved_llvm_source_archive STREQUAL "")
      stage0_ensure_default_archive(
        _resolved_llvm_source_archive
        "llvm-project source archive"
        "${STAGE0_CACHE_DIR}"
        "llvm-project-18.1.8.src.tar.xz"
        "${STAGE0_LLVM_SOURCE_URL}")
    endif()
    set(STAGE0_LLVM_SOURCE_ARCHIVE "${_resolved_llvm_source_archive}")
  endif()
  stage0_archive_stem("${STAGE0_LLVM_SOURCE_ARCHIVE}" _llvm_source_stem)
  set(_llvm_source_extract_dir "${STAGE0_SOURCE_DIR}/llvm/${_llvm_source_stem}")
  stage0_extract_archive_once("${STAGE0_LLVM_SOURCE_ARCHIVE}" "${_llvm_source_extract_dir}")
  stage0_unwrap_single_subdir("${_llvm_source_extract_dir}" "llvm/CMakeLists.txt" STAGE0_LLVM_SOURCE_DIR)
endif()

find_program(STAGE0_MAKE_PROGRAM NAMES gmake make REQUIRED)
find_program(STAGE0_CP_PROGRAM NAMES cp REQUIRED)
find_program(STAGE0_HOST_CC NAMES cc clang gcc REQUIRED)
find_program(STAGE0_HOST_CXX NAMES c++ clang++ g++ REQUIRED)
find_program(STAGE0_READELF NAMES llvm-readelf readelf REQUIRED)

set(STAGE0_LLVM_BIN_DIR "${STAGE0_CLANG_ROOT}/bin")
set(STAGE0_ROOTFS_DIR "${STAGE0_OUTPUT_DIR}/${STAGE0_TARGET_TRIPLE}/rootfs")
set(STAGE0_BUSYBOX_SYSROOT_DIR "${STAGE0_ROOTFS_DIR}")
set(STAGE0_TOOLCHAIN_DIR "${CMAKE_BINARY_DIR}/toolchain/${STAGE0_TARGET_TRIPLE}")
set(STAGE0_TARGET_CC_WRAPPER "${STAGE0_TOOLCHAIN_DIR}/clang-target.sh")
set(STAGE0_TARGET_CROSS_PREFIX "${STAGE0_TOOLCHAIN_DIR}/${STAGE0_TARGET_TRIPLE}-")
set(STAGE0_TARGET_RESOURCE_DIR "${STAGE0_TOOLCHAIN_DIR}/clang-resource")
set(STAGE0_TARGET_CRT_DIR "${STAGE0_TOOLCHAIN_DIR}/crt")
set(STAGE0_BUSYBOX_BUILD_DIR "${STAGE0_BUSYBOX_SOURCE_DIR}")
set(STAGE0_LLVM_RUNTIMES_BUILD_ROOT "${CMAKE_BINARY_DIR}/llvm-runtimes/${STAGE0_TARGET_TRIPLE}")
set(STAGE0_LLVM_RUNTIMES_BUILD_DIR "${STAGE0_LLVM_RUNTIMES_BUILD_ROOT}/all")
set(STAGE0_LLVM_COMPILER_RT_BUILD_DIR "${STAGE0_LLVM_RUNTIMES_BUILD_ROOT}/compiler-rt")
set(STAGE0_LLVM_UNWIND_BUILD_DIR "${STAGE0_LLVM_RUNTIMES_BUILD_ROOT}/libunwind")
set(STAGE0_LLVM_CXX_RUNTIMES_BUILD_DIR "${STAGE0_LLVM_RUNTIMES_BUILD_ROOT}/cxx")
set(STAGE0_LLVM_RUNTIMES_INSTALL_PREFIX "${STAGE0_ROOTFS_DIR}/usr")
set(STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR "${STAGE0_ROOTFS_DIR}/usr/lib/${STAGE0_TARGET_TRIPLE}")
stage0_normalize_host_arch("${CMAKE_HOST_SYSTEM_PROCESSOR}" STAGE0_HOST_ARCH)

foreach(_required_tool clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-ranlib llvm-strip)
  if(NOT EXISTS "${STAGE0_LLVM_BIN_DIR}/${_required_tool}")
    message(FATAL_ERROR "Required LLVM tool not found: ${STAGE0_LLVM_BIN_DIR}/${_required_tool}")
  endif()
endforeach()

execute_process(
  COMMAND "${STAGE0_LLVM_BIN_DIR}/clang" --print-resource-dir
  RESULT_VARIABLE _stage0_resource_dir_status
  OUTPUT_VARIABLE STAGE0_HOST_CLANG_RESOURCE_DIR
  ERROR_VARIABLE _stage0_resource_dir_error
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_STRIP_TRAILING_WHITESPACE)
if(NOT _stage0_resource_dir_status EQUAL 0)
  message(FATAL_ERROR
    "Failed to query clang resource dir from ${STAGE0_LLVM_BIN_DIR}/clang: "
    "${_stage0_resource_dir_error}")
endif()

execute_process(
  COMMAND "${STAGE0_LLVM_BIN_DIR}/clang" "--target=${STAGE0_TARGET_TRIPLE}" --rtlib=compiler-rt -print-libgcc-file-name
  RESULT_VARIABLE _stage0_builtins_probe_status
  OUTPUT_VARIABLE _stage0_builtins_probe_output
  ERROR_VARIABLE _stage0_builtins_probe_error
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_STRIP_TRAILING_WHITESPACE)
if(NOT _stage0_builtins_probe_status EQUAL 0)
  message(FATAL_ERROR
    "Failed to probe compiler-rt builtins path for ${STAGE0_TARGET_TRIPLE}: "
    "${_stage0_builtins_probe_error}")
endif()

file(RELATIVE_PATH STAGE0_TARGET_BUILTINS_RELATIVE_PATH
  "${STAGE0_HOST_CLANG_RESOURCE_DIR}"
  "${_stage0_builtins_probe_output}")
if(STAGE0_TARGET_BUILTINS_RELATIVE_PATH MATCHES "^\\.\\.")
  message(FATAL_ERROR
    "clang reported a builtins path outside its resource dir for ${STAGE0_TARGET_TRIPLE}: "
    "${_stage0_builtins_probe_output}")
endif()

if(NOT EXISTS "${STAGE0_TARGET_SYSROOT_DIR}/usr")
  message(FATAL_ERROR "Target sysroot does not look valid: ${STAGE0_TARGET_SYSROOT_DIR}")
endif()

if(NOT EXISTS "${STAGE0_BUSYBOX_SOURCE_DIR}/Makefile")
  message(FATAL_ERROR "BusyBox source tree does not look valid: ${STAGE0_BUSYBOX_SOURCE_DIR}")
endif()

if(NOT EXISTS "${STAGE0_LLVM_SOURCE_DIR}/llvm/CMakeLists.txt")
  message(FATAL_ERROR "llvm-project source tree does not look valid: ${STAGE0_LLVM_SOURCE_DIR}")
endif()

if(NOT EXISTS "${STAGE0_LLVM_SOURCE_DIR}/runtimes/CMakeLists.txt")
  message(FATAL_ERROR "llvm-project runtimes tree does not look valid: ${STAGE0_LLVM_SOURCE_DIR}")
endif()

if(NOT STAGE0_BUSYBOX_CONFIG_FRAGMENT STREQUAL "" AND NOT EXISTS "${STAGE0_BUSYBOX_CONFIG_FRAGMENT}")
  message(FATAL_ERROR "BusyBox config fragment does not exist: ${STAGE0_BUSYBOX_CONFIG_FRAGMENT}")
endif()

if(STAGE0_LLVM_RUNTIME_COMPONENTS STREQUAL "")
  message(FATAL_ERROR "STAGE0_LLVM_RUNTIME_COMPONENTS must not be empty.")
endif()

set(_stage0_runtime_components ${STAGE0_LLVM_RUNTIME_COMPONENTS})
set(_stage0_has_compiler_rt_runtime FALSE)
set(_stage0_has_libunwind_runtime FALSE)
set(_stage0_cxx_runtime_components "")
foreach(_stage0_runtime_component IN LISTS _stage0_runtime_components)
  if(_stage0_runtime_component STREQUAL "compiler-rt")
    set(_stage0_has_compiler_rt_runtime TRUE)
  elseif(_stage0_runtime_component STREQUAL "libunwind")
    set(_stage0_has_libunwind_runtime TRUE)
  else()
    list(APPEND _stage0_cxx_runtime_components "${_stage0_runtime_component}")
  endif()
endforeach()
list(JOIN _stage0_cxx_runtime_components ";" _stage0_cxx_runtime_components_value)
string(REPLACE ";" "\\;" _stage0_cxx_runtime_components_value_escaped "${_stage0_cxx_runtime_components_value}")
set(_stage0_cxx_phase_runtime_components ${_stage0_cxx_runtime_components})
if(_stage0_has_libunwind_runtime AND _stage0_cxx_runtime_components)
  list(INSERT _stage0_cxx_phase_runtime_components 0 "libunwind")
endif()
list(JOIN _stage0_cxx_phase_runtime_components ";" _stage0_cxx_phase_runtime_components_value)
string(REPLACE ";" "\\;" _stage0_cxx_phase_runtime_components_value_escaped "${_stage0_cxx_phase_runtime_components_value}")

set(_stage0_runtime_root_libdirs "")
set(_stage0_runtime_root_libdir_realpaths "")
foreach(_stage0_root_lib_candidate IN ITEMS lib64 lib)
  if(EXISTS "${STAGE0_TARGET_SYSROOT_DIR}/${_stage0_root_lib_candidate}")
    file(REAL_PATH
      "${STAGE0_TARGET_SYSROOT_DIR}/${_stage0_root_lib_candidate}"
      _stage0_root_lib_candidate_realpath)
    list(FIND
      _stage0_runtime_root_libdir_realpaths
      "${_stage0_root_lib_candidate_realpath}"
      _stage0_root_lib_candidate_realpath_index)
    if(_stage0_root_lib_candidate_realpath_index EQUAL -1)
      list(APPEND _stage0_runtime_root_libdirs "${_stage0_root_lib_candidate}")
      list(APPEND _stage0_runtime_root_libdir_realpaths "${_stage0_root_lib_candidate_realpath}")
    endif()
  endif()
endforeach()
if(NOT _stage0_runtime_root_libdirs)
  list(APPEND _stage0_runtime_root_libdirs "lib")
endif()

set(_stage0_runtime_usr_libdirs "")
set(_stage0_runtime_usr_libdir_realpaths "")
foreach(_stage0_usr_lib_candidate IN ITEMS usr/lib64 usr/lib)
  if(EXISTS "${STAGE0_TARGET_SYSROOT_DIR}/${_stage0_usr_lib_candidate}")
    file(REAL_PATH
      "${STAGE0_TARGET_SYSROOT_DIR}/${_stage0_usr_lib_candidate}"
      _stage0_usr_lib_candidate_realpath)
    list(FIND
      _stage0_runtime_usr_libdir_realpaths
      "${_stage0_usr_lib_candidate_realpath}"
      _stage0_usr_lib_candidate_realpath_index)
    if(_stage0_usr_lib_candidate_realpath_index EQUAL -1)
      list(APPEND _stage0_runtime_usr_libdirs "${_stage0_usr_lib_candidate}")
      list(APPEND _stage0_runtime_usr_libdir_realpaths "${_stage0_usr_lib_candidate_realpath}")
    endif()
  endif()
endforeach()
if(NOT _stage0_runtime_usr_libdirs)
  list(APPEND _stage0_runtime_usr_libdirs "usr/lib")
endif()

string(TOUPPER "${STAGE0_CXX_RUNTIMES_USE_COMPILER_RT}" _stage0_cxx_runtimes_use_compiler_rt_mode)
if(_stage0_cxx_runtimes_use_compiler_rt_mode STREQUAL "AUTO")
  set(_stage0_cxx_runtimes_use_compiler_rt "${_stage0_has_compiler_rt_runtime}")
elseif(_stage0_cxx_runtimes_use_compiler_rt_mode STREQUAL "ON" OR _stage0_cxx_runtimes_use_compiler_rt_mode STREQUAL "OFF")
  set(_stage0_cxx_runtimes_use_compiler_rt "${_stage0_cxx_runtimes_use_compiler_rt_mode}")
else()
  message(FATAL_ERROR
    "STAGE0_CXX_RUNTIMES_USE_COMPILER_RT must be AUTO, ON, or OFF. "
    "Got: ${STAGE0_CXX_RUNTIMES_USE_COMPILER_RT}")
endif()

if(_stage0_cxx_runtimes_use_compiler_rt AND NOT _stage0_has_compiler_rt_runtime)
  message(FATAL_ERROR
    "STAGE0_CXX_RUNTIMES_USE_COMPILER_RT=${STAGE0_CXX_RUNTIMES_USE_COMPILER_RT}, "
    "but compiler-rt is not present in STAGE0_LLVM_RUNTIME_COMPONENTS.")
endif()

string(TOUPPER "${STAGE0_LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL}" _stage0_cxa_thread_atexit_mode)
if(_stage0_cxa_thread_atexit_mode STREQUAL "AUTO")
  file(GLOB _stage0_libc_candidates
    LIST_DIRECTORIES FALSE
    "${STAGE0_TARGET_SYSROOT_DIR}/lib/libc.so.6"
    "${STAGE0_TARGET_SYSROOT_DIR}/lib64/libc.so.6"
    "${STAGE0_TARGET_SYSROOT_DIR}/usr/lib/libc.so.6"
    "${STAGE0_TARGET_SYSROOT_DIR}/usr/lib64/libc.so.6")
  set(_stage0_detected_cxa_thread_atexit FALSE)
  foreach(_stage0_libc_candidate IN LISTS _stage0_libc_candidates)
    stage0_detect_elf_symbol(
      "${_stage0_libc_candidate}"
      "__cxa_thread_atexit_impl"
      _stage0_libc_has_cxa_thread_atexit_impl)
    if(_stage0_libc_has_cxa_thread_atexit_impl)
      set(_stage0_detected_cxa_thread_atexit TRUE)
      break()
    endif()
  endforeach()
  if(_stage0_detected_cxa_thread_atexit)
    set(_stage0_cxa_thread_atexit_value ON)
  else()
    set(_stage0_cxa_thread_atexit_value OFF)
  endif()
elseif(_stage0_cxa_thread_atexit_mode STREQUAL "ON" OR _stage0_cxa_thread_atexit_mode STREQUAL "OFF")
  set(_stage0_cxa_thread_atexit_value "${_stage0_cxa_thread_atexit_mode}")
else()
  message(FATAL_ERROR
    "STAGE0_LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL must be AUTO, ON, or OFF. "
    "Got: ${STAGE0_LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL}")
endif()

if(_stage0_cxx_runtime_components AND NOT _stage0_has_compiler_rt_runtime)
  message(WARNING
    "Target ${STAGE0_TARGET_TRIPLE} is building C/C++ runtimes without compiler-rt "
    "in STAGE0_LLVM_RUNTIME_COMPONENTS. clang may not have the required builtins/crt "
    "objects for this target.")
endif()

set(_stage0_runtime_common_cmake_args
  "-DCMAKE_BUILD_TYPE=${STAGE0_LLVM_RUNTIME_BUILD_TYPE}"
  "-DCMAKE_VERBOSE_MAKEFILE=${STAGE0_VERBOSE_BUILD}"
  "-DCMAKE_INSTALL_PREFIX=${STAGE0_LLVM_RUNTIMES_INSTALL_PREFIX}"
  "-DCMAKE_C_COMPILER=${STAGE0_LLVM_BIN_DIR}/clang"
  "-DCMAKE_CXX_COMPILER=${STAGE0_LLVM_BIN_DIR}/clang++"
  "-DCMAKE_ASM_COMPILER=${STAGE0_LLVM_BIN_DIR}/clang"
  "-DCMAKE_LINKER=${STAGE0_LLVM_BIN_DIR}/ld.lld"
  "-DCMAKE_AR=${STAGE0_LLVM_BIN_DIR}/llvm-ar"
  "-DCMAKE_NM=${STAGE0_LLVM_BIN_DIR}/llvm-nm"
  "-DCMAKE_OBJCOPY=${STAGE0_LLVM_BIN_DIR}/llvm-objcopy"
  "-DCMAKE_RANLIB=${STAGE0_LLVM_BIN_DIR}/llvm-ranlib"
  "-DCMAKE_STRIP=${STAGE0_LLVM_BIN_DIR}/llvm-strip"
  "-DCMAKE_C_COMPILER_TARGET=${STAGE0_TARGET_TRIPLE}"
  "-DCMAKE_CXX_COMPILER_TARGET=${STAGE0_TARGET_TRIPLE}"
  "-DCMAKE_ASM_COMPILER_TARGET=${STAGE0_TARGET_TRIPLE}"
  "-DCMAKE_SYSROOT=${STAGE0_ROOTFS_DIR}"
  "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
  "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld"
  "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld"
  "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld"
  "-DLLVM_PATH=${STAGE0_LLVM_SOURCE_DIR}/llvm"
  "-DLLVM_DEFAULT_TARGET_TRIPLE=${STAGE0_TARGET_TRIPLE}"
  "-DLLVM_INCLUDE_TESTS=OFF"
  "-DLLVM_INCLUDE_DOCS=OFF"
  "-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON"
  "-DLIBUNWIND_INCLUDE_TESTS=OFF"
  "-DLIBCXXABI_INCLUDE_TESTS=OFF"
  "-DLIBCXX_INCLUDE_TESTS=OFF"
  "-DLIBCXX_INCLUDE_BENCHMARKS=OFF"
  "-DLIBCXX_CXX_ABI=libcxxabi")

set(_stage0_compiler_rt_cmake_args
  ${_stage0_runtime_common_cmake_args}
  "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
  "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON"
  "-DCOMPILER_RT_BUILD_BUILTINS=ON"
  "-DCOMPILER_RT_BUILD_CRT=ON"
  "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
  "-DCOMPILER_RT_BUILD_XRAY=OFF"
  "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
  "-DCOMPILER_RT_BUILD_PROFILE=OFF"
  "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
  "-DCOMPILER_RT_BUILD_GWP_ASAN=OFF"
  "-DCOMPILER_RT_BUILD_ORC=OFF")

set(_stage0_cxx_runtime_cmake_args
  ${_stage0_runtime_common_cmake_args}
  "-DLLVM_ENABLE_RUNTIMES=${_stage0_cxx_runtime_components_value_escaped}"
  "-DLIBUNWIND_USE_COMPILER_RT=OFF"
  "-DLIBCXXABI_USE_COMPILER_RT=OFF"
  "-DLIBCXXABI_USE_LLVM_UNWINDER=ON"
  "-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=${_stage0_cxa_thread_atexit_value}"
  "-DLIBCXX_USE_COMPILER_RT=OFF")

set(_stage0_target_wrapper_always_flags
  "-resource-dir=${STAGE0_TARGET_RESOURCE_DIR}"
  "-B${STAGE0_TARGET_CRT_DIR}")
list(JOIN _stage0_target_wrapper_always_flags " " _stage0_target_wrapper_always_flags_value)

set(_stage0_target_runtime_link_args "")
if(_stage0_cxx_runtimes_use_compiler_rt)
  list(APPEND _stage0_target_runtime_link_args "--rtlib=compiler-rt")
endif()
list(JOIN _stage0_target_runtime_link_args " " _stage0_target_runtime_link_flags_value)

set(_stage0_target_runtime_library_search_args
  "-L${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}")
list(JOIN _stage0_target_runtime_library_search_args " " _stage0_target_runtime_library_search_flags_value)

set(_stage0_target_runtime_link_args_with_unwind ${_stage0_target_runtime_link_args})
if(_stage0_has_libunwind_runtime)
  list(APPEND _stage0_target_runtime_link_args_with_unwind "--unwindlib=libunwind")
endif()
list(JOIN _stage0_target_runtime_link_args_with_unwind " " _stage0_target_runtime_link_flags_with_unwind_value)

set(_stage0_unwind_runtime_cmake_args
  ${_stage0_runtime_common_cmake_args}
  "-DLLVM_ENABLE_RUNTIMES=libunwind"
  "-DLIBUNWIND_USE_COMPILER_RT=${_stage0_cxx_runtimes_use_compiler_rt}"
  "-DLIBUNWIND_INCLUDE_TESTS=OFF"
  "-DCMAKE_C_FLAGS=${_stage0_target_wrapper_always_flags_value}"
  "-DCMAKE_CXX_FLAGS=${_stage0_target_wrapper_always_flags_value}"
  "-DCMAKE_ASM_FLAGS=${_stage0_target_wrapper_always_flags_value}"
  "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld ${_stage0_target_wrapper_always_flags_value} ${_stage0_target_runtime_library_search_flags_value} ${_stage0_target_runtime_link_flags_value}"
  "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld ${_stage0_target_wrapper_always_flags_value} ${_stage0_target_runtime_library_search_flags_value} ${_stage0_target_runtime_link_flags_value}"
  "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld ${_stage0_target_wrapper_always_flags_value} ${_stage0_target_runtime_library_search_flags_value} ${_stage0_target_runtime_link_flags_value}")

if(_stage0_cxx_runtime_components)
  set(_stage0_cxx_runtime_cmake_args
    ${_stage0_runtime_common_cmake_args}
    "-DLLVM_ENABLE_RUNTIMES=${_stage0_cxx_phase_runtime_components_value_escaped}"
    "-DLIBUNWIND_USE_COMPILER_RT=${_stage0_cxx_runtimes_use_compiler_rt}"
    "-DLIBCXXABI_USE_COMPILER_RT=${_stage0_cxx_runtimes_use_compiler_rt}"
    "-DLIBCXXABI_USE_LLVM_UNWINDER=ON"
    "-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=${_stage0_cxa_thread_atexit_value}"
    "-DLIBCXX_USE_COMPILER_RT=${_stage0_cxx_runtimes_use_compiler_rt}"
    "-DCMAKE_C_FLAGS=${_stage0_target_wrapper_always_flags_value}"
    "-DCMAKE_CXX_FLAGS=${_stage0_target_wrapper_always_flags_value}"
    "-DCMAKE_ASM_FLAGS=${_stage0_target_wrapper_always_flags_value}"
    "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld ${_stage0_target_wrapper_always_flags_value} ${_stage0_target_runtime_library_search_flags_value} ${_stage0_target_runtime_link_flags_value}"
    "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld ${_stage0_target_wrapper_always_flags_value} ${_stage0_target_runtime_library_search_flags_value} ${_stage0_target_runtime_link_flags_value}"
    "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld ${_stage0_target_wrapper_always_flags_value} ${_stage0_target_runtime_library_search_flags_value} ${_stage0_target_runtime_link_flags_value}")
endif()

set(STAGE0_TARGET_WRAPPER_ALWAYS_ARGS "")
foreach(_stage0_wrapper_arg IN LISTS _stage0_target_wrapper_always_flags)
  string(APPEND STAGE0_TARGET_WRAPPER_ALWAYS_ARGS
    "    \"${_stage0_wrapper_arg}\" \\\n")
endforeach()

set(STAGE0_TARGET_WRAPPER_LINK_ARGS "")
foreach(_stage0_wrapper_arg IN LISTS _stage0_target_runtime_link_args_with_unwind)
  string(APPEND STAGE0_TARGET_WRAPPER_LINK_ARGS
    "    \"${_stage0_wrapper_arg}\" \\\n")
endforeach()

file(MAKE_DIRECTORY "${STAGE0_TOOLCHAIN_DIR}")
file(MAKE_DIRECTORY "${STAGE0_TARGET_RESOURCE_DIR}")
file(MAKE_DIRECTORY "${STAGE0_TARGET_CRT_DIR}")
file(MAKE_DIRECTORY "${STAGE0_TMP_DIR}")
configure_file(
  "${CMAKE_CURRENT_LIST_DIR}/cmake/clang-target.sh.in"
  "${STAGE0_TARGET_CC_WRAPPER}"
  @ONLY)
file(CHMOD
  "${STAGE0_TARGET_CC_WRAPPER}"
  PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE
    GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)

set(_stage0_prefixed_tool_names
  gcc
  cc
  ar
  nm
  objcopy
  ranlib
  strip)
set(_stage0_prefixed_tool_targets
  "${STAGE0_TARGET_CC_WRAPPER}"
  "${STAGE0_TARGET_CC_WRAPPER}"
  "${STAGE0_LLVM_BIN_DIR}/llvm-ar"
  "${STAGE0_LLVM_BIN_DIR}/llvm-nm"
  "${STAGE0_LLVM_BIN_DIR}/llvm-objcopy"
  "${STAGE0_LLVM_BIN_DIR}/llvm-ranlib"
  "${STAGE0_LLVM_BIN_DIR}/llvm-strip")

list(LENGTH _stage0_prefixed_tool_names _stage0_prefixed_tool_count)
math(EXPR _stage0_prefixed_tool_last "${_stage0_prefixed_tool_count} - 1")
foreach(_stage0_prefixed_tool_index RANGE ${_stage0_prefixed_tool_last})
  list(GET _stage0_prefixed_tool_names ${_stage0_prefixed_tool_index} _stage0_tool_name)
  list(GET _stage0_prefixed_tool_targets ${_stage0_prefixed_tool_index} _stage0_tool_target)
  set(_stage0_prefixed_tool_path "${STAGE0_TARGET_CROSS_PREFIX}${_stage0_tool_name}")
  if(EXISTS "${_stage0_prefixed_tool_path}" OR IS_SYMLINK "${_stage0_prefixed_tool_path}")
    file(REMOVE "${_stage0_prefixed_tool_path}")
  endif()
  file(CREATE_LINK "${_stage0_tool_target}" "${_stage0_prefixed_tool_path}" SYMBOLIC)
endforeach()

set(_llvm_runtime_generator_args "")
if(CMAKE_GENERATOR)
  list(APPEND _llvm_runtime_generator_args -G "${CMAKE_GENERATOR}")
endif()
if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "")
  list(APPEND _llvm_runtime_generator_args -A "${CMAKE_GENERATOR_PLATFORM}")
endif()
if(NOT CMAKE_GENERATOR_TOOLSET STREQUAL "")
  list(APPEND _llvm_runtime_generator_args -T "${CMAKE_GENERATOR_TOOLSET}")
endif()

set(_busybox_env
  "KCONFIG_NOTIMESTAMP=1"
  "TMPDIR=${STAGE0_TMP_DIR}"
  "TMP=${STAGE0_TMP_DIR}"
  "TEMP=${STAGE0_TMP_DIR}"
  "TEMPDIR=${STAGE0_TMP_DIR}"
  "HOSTCC=${STAGE0_HOST_CC}"
  "HOSTCXX=${STAGE0_HOST_CXX}"
  "CC=${STAGE0_TARGET_CC_WRAPPER}"
  "LD=${STAGE0_TARGET_CC_WRAPPER}"
  "AR=${STAGE0_LLVM_BIN_DIR}/llvm-ar"
  "NM=${STAGE0_LLVM_BIN_DIR}/llvm-nm"
  "OBJCOPY=${STAGE0_LLVM_BIN_DIR}/llvm-objcopy"
  "RANLIB=${STAGE0_LLVM_BIN_DIR}/llvm-ranlib"
  "STRIP=${STAGE0_LLVM_BIN_DIR}/llvm-strip"
  "CROSS_COMPILE=${STAGE0_TARGET_CROSS_PREFIX}")

if(NOT STAGE0_BUSYBOX_EXTRA_CFLAGS STREQUAL "")
  list(APPEND _busybox_env "EXTRA_CFLAGS=${STAGE0_BUSYBOX_EXTRA_CFLAGS}")
endif()

if(NOT STAGE0_BUSYBOX_EXTRA_LDFLAGS STREQUAL "")
  list(APPEND _busybox_env "EXTRA_LDFLAGS=${STAGE0_BUSYBOX_EXTRA_LDFLAGS}")
endif()

set(_busybox_make_args -C "${STAGE0_BUSYBOX_SOURCE_DIR}")
set(_busybox_parallel_args "")
if(STAGE0_JOBS)
  list(APPEND _busybox_parallel_args "-j${STAGE0_JOBS}")
endif()

set(_busybox_verbose_args "")
set(_llvm_runtime_build_verbose_args "")
if(STAGE0_VERBOSE_BUILD)
  list(APPEND _busybox_verbose_args "V=1")
  list(APPEND _llvm_runtime_build_verbose_args --verbose)
endif()

set(_llvm_runtime_parallel_args "")
if(STAGE0_JOBS)
  list(APPEND _llvm_runtime_parallel_args --parallel "${STAGE0_JOBS}")
endif()

set(_stage0_runtime_configure_env
  "TMPDIR=${STAGE0_TMP_DIR}"
  "TMP=${STAGE0_TMP_DIR}"
  "TEMP=${STAGE0_TMP_DIR}"
  "TEMPDIR=${STAGE0_TMP_DIR}")

set(_sysroot_stage_stamp "${STAGE0_ROOTFS_DIR}/.sysroot-staged")
add_custom_command(
  OUTPUT "${_sysroot_stage_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${STAGE0_ROOTFS_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE0_ROOTFS_DIR}"
  COMMAND "${STAGE0_CP_PROGRAM}" -a "${STAGE0_TARGET_SYSROOT_DIR}/." "${STAGE0_ROOTFS_DIR}/"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_sysroot_stage_stamp}"
  DEPENDS "${STAGE0_TARGET_SYSROOT_DIR}/usr"
  COMMENT "Staging sysroot into ${STAGE0_ROOTFS_DIR}"
  VERBATIM)

set(_llvm_compiler_rt_stamp "${STAGE0_ROOTFS_DIR}/.llvm-compiler-rt-installed")
if(_stage0_has_compiler_rt_runtime)
  add_custom_command(
    OUTPUT "${_llvm_compiler_rt_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${STAGE0_LLVM_COMPILER_RT_BUILD_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE0_LLVM_COMPILER_RT_BUILD_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage0_runtime_configure_env}
      "${CMAKE_COMMAND}"
      ${_llvm_runtime_generator_args}
      -S "${STAGE0_LLVM_SOURCE_DIR}/runtimes"
      -B "${STAGE0_LLVM_COMPILER_RT_BUILD_DIR}"
      ${_stage0_compiler_rt_cmake_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage0_runtime_configure_env}
      "${CMAKE_COMMAND}"
      --build "${STAGE0_LLVM_COMPILER_RT_BUILD_DIR}"
      --target install
      ${_llvm_runtime_parallel_args}
      ${_llvm_runtime_build_verbose_args}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_compiler_rt_stamp}"
    DEPENDS
      "${_sysroot_stage_stamp}"
      "${STAGE0_LLVM_SOURCE_DIR}/llvm/CMakeLists.txt"
    COMMENT "Building compiler-rt for ${STAGE0_TARGET_TRIPLE}"
    USES_TERMINAL
    VERBATIM)
else()
  add_custom_command(
    OUTPUT "${_llvm_compiler_rt_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_compiler_rt_stamp}"
    DEPENDS "${_sysroot_stage_stamp}"
    COMMENT "Skipping compiler-rt for ${STAGE0_TARGET_TRIPLE}"
    VERBATIM)
endif()

set(_llvm_compiler_rt_driver_overlay_stamp "${STAGE0_ROOTFS_DIR}/.llvm-compiler-rt-driver-overlay-staged")
if(_stage0_has_compiler_rt_runtime)
  add_custom_command(
    OUTPUT "${_llvm_compiler_rt_driver_overlay_stamp}"
    COMMAND "${CMAKE_COMMAND}"
      "-DCLANG_RESOURCE_DIR=${STAGE0_TARGET_RESOURCE_DIR}"
      "-DHOST_CLANG_RESOURCE_DIR=${STAGE0_HOST_CLANG_RESOURCE_DIR}"
      "-DBUILTINS_SOURCE=${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}/libclang_rt.builtins.a"
      "-DBUILTINS_RELATIVE_PATH=${STAGE0_TARGET_BUILTINS_RELATIVE_PATH}"
      "-DCRT_DIR=${STAGE0_TARGET_CRT_DIR}"
      "-DCRTBEGIN_SOURCE=${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}/clang_rt.crtbegin.o"
      "-DCRTEND_SOURCE=${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}/clang_rt.crtend.o"
      -P "${CMAKE_CURRENT_LIST_DIR}/cmake/stage_clang_runtime_overlay.cmake"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_compiler_rt_driver_overlay_stamp}"
    DEPENDS "${_llvm_compiler_rt_stamp}"
    COMMENT "Staging clang compiler-rt driver overlay for ${STAGE0_TARGET_TRIPLE}"
    VERBATIM)
else()
  add_custom_command(
    OUTPUT "${_llvm_compiler_rt_driver_overlay_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_compiler_rt_driver_overlay_stamp}"
    DEPENDS "${_llvm_compiler_rt_stamp}"
    COMMENT "Skipping clang compiler-rt driver overlay for ${STAGE0_TARGET_TRIPLE}"
    VERBATIM)
endif()

set(_llvm_unwind_stamp "${STAGE0_ROOTFS_DIR}/.llvm-libunwind-installed")
if(_stage0_has_libunwind_runtime)
  add_custom_command(
    OUTPUT "${_llvm_unwind_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${STAGE0_LLVM_UNWIND_BUILD_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE0_LLVM_UNWIND_BUILD_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage0_runtime_configure_env}
      "${CMAKE_COMMAND}"
      ${_llvm_runtime_generator_args}
      -S "${STAGE0_LLVM_SOURCE_DIR}/runtimes"
      -B "${STAGE0_LLVM_UNWIND_BUILD_DIR}"
      ${_stage0_unwind_runtime_cmake_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage0_runtime_configure_env}
      "${CMAKE_COMMAND}"
      --build "${STAGE0_LLVM_UNWIND_BUILD_DIR}"
      --target install
      ${_llvm_runtime_parallel_args}
      ${_llvm_runtime_build_verbose_args}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_unwind_stamp}"
    DEPENDS
      "${_llvm_compiler_rt_driver_overlay_stamp}"
      "${STAGE0_LLVM_SOURCE_DIR}/llvm/CMakeLists.txt"
    COMMENT "Building libunwind for ${STAGE0_TARGET_TRIPLE}"
    USES_TERMINAL
    VERBATIM)
else()
  add_custom_command(
    OUTPUT "${_llvm_unwind_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_unwind_stamp}"
    DEPENDS "${_llvm_compiler_rt_driver_overlay_stamp}"
    COMMENT "Skipping libunwind for ${STAGE0_TARGET_TRIPLE}"
    VERBATIM)
endif()

set(_llvm_cxx_runtimes_stamp "${STAGE0_ROOTFS_DIR}/.llvm-cxx-runtimes-installed")
if(_stage0_cxx_runtime_components)
  add_custom_command(
    OUTPUT "${_llvm_cxx_runtimes_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${STAGE0_LLVM_CXX_RUNTIMES_BUILD_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE0_LLVM_CXX_RUNTIMES_BUILD_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage0_runtime_configure_env}
      "${CMAKE_COMMAND}"
      ${_llvm_runtime_generator_args}
      -S "${STAGE0_LLVM_SOURCE_DIR}/runtimes"
      -B "${STAGE0_LLVM_CXX_RUNTIMES_BUILD_DIR}"
      ${_stage0_cxx_runtime_cmake_args}
    COMMAND "${CMAKE_COMMAND}" -E env
      ${_stage0_runtime_configure_env}
      "${CMAKE_COMMAND}"
      --build "${STAGE0_LLVM_CXX_RUNTIMES_BUILD_DIR}"
      --target install
      ${_llvm_runtime_parallel_args}
      ${_llvm_runtime_build_verbose_args}
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_cxx_runtimes_stamp}"
    DEPENDS
      "${_llvm_unwind_stamp}"
      "${STAGE0_LLVM_SOURCE_DIR}/llvm/CMakeLists.txt"
    COMMENT "Building C/C++ runtimes for ${STAGE0_TARGET_TRIPLE}"
    USES_TERMINAL
    VERBATIM)
else()
  add_custom_command(
    OUTPUT "${_llvm_cxx_runtimes_stamp}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_cxx_runtimes_stamp}"
    DEPENDS "${_llvm_unwind_stamp}"
    COMMENT "Skipping C/C++ runtimes for ${STAGE0_TARGET_TRIPLE}"
    VERBATIM)
endif()

set(_llvm_runtimes_stamp "${STAGE0_ROOTFS_DIR}/.llvm-runtimes-installed")
add_custom_command(
  OUTPUT "${_llvm_runtimes_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_runtimes_stamp}"
  DEPENDS "${_llvm_cxx_runtimes_stamp}"
  COMMENT "Collecting LLVM runtime stamps for ${STAGE0_TARGET_TRIPLE}"
  VERBATIM)

set(_llvm_runtime_layout_stamp "${STAGE0_ROOTFS_DIR}/.llvm-runtimes-layout-staged")
add_custom_command(
  OUTPUT "${_llvm_runtime_layout_stamp}"
  COMMAND "${CMAKE_COMMAND}"
    "-DROOTFS_DIR=${STAGE0_ROOTFS_DIR}"
    "-DSOURCE_LIBDIR=${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}"
    "-DROOT_SHARED_LIB_DIRS=${_stage0_runtime_root_libdirs}"
    "-DUSR_DEV_LIB_DIRS=${_stage0_runtime_usr_libdirs}"
    -P "${CMAKE_CURRENT_LIST_DIR}/cmake/stage_runtime_layout.cmake"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_llvm_runtime_layout_stamp}"
  DEPENDS "${_llvm_runtimes_stamp}"
  COMMENT "Staging LLVM runtimes into distro-style sysroot lib directories"
  VERBATIM)

add_custom_command(
  OUTPUT "${STAGE0_BUSYBOX_BUILD_DIR}/.config"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${STAGE0_BUSYBOX_BUILD_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E env
    ${_busybox_env}
    "${STAGE0_MAKE_PROGRAM}"
    ${_busybox_make_args}
    ${_busybox_verbose_args}
    "${STAGE0_BUSYBOX_CONFIG_TARGET}"
  COMMAND "${CMAKE_COMMAND}"
    "-DCONFIG_FILE=${STAGE0_BUSYBOX_BUILD_DIR}/.config"
    "-DFRAGMENT_FILE=${STAGE0_BUSYBOX_CONFIG_FRAGMENT}"
    "-DOVERRIDE_CROSS_COMPILER_PREFIX=${STAGE0_TARGET_CROSS_PREFIX}"
    "-DOVERRIDE_SYSROOT=${STAGE0_BUSYBOX_SYSROOT_DIR}"
    -P "${CMAKE_CURRENT_LIST_DIR}/cmake/merge_busybox_config.cmake"
  COMMAND "${CMAKE_COMMAND}" -E env
    ${_busybox_env}
    "${STAGE0_MAKE_PROGRAM}"
    ${_busybox_make_args}
    ${_busybox_verbose_args}
    silentoldconfig
  DEPENDS "${STAGE0_BUSYBOX_SOURCE_DIR}/Makefile" "${_sysroot_stage_stamp}"
  COMMENT "Configuring BusyBox for ${STAGE0_TARGET_TRIPLE}"
  USES_TERMINAL
  VERBATIM)

add_custom_command(
  OUTPUT "${STAGE0_BUSYBOX_BUILD_DIR}/busybox"
  COMMAND "${CMAKE_COMMAND}" -E env
    ${_busybox_env}
    "${STAGE0_MAKE_PROGRAM}"
    ${_busybox_make_args}
    ${_busybox_verbose_args}
    ${_busybox_parallel_args}
  DEPENDS "${STAGE0_BUSYBOX_BUILD_DIR}/.config" "${_llvm_runtime_layout_stamp}"
  COMMENT "Building BusyBox for ${STAGE0_TARGET_TRIPLE}"
  USES_TERMINAL
  VERBATIM)

set(_busybox_install_stamp "${STAGE0_ROOTFS_DIR}/.busybox-installed")
add_custom_command(
  OUTPUT "${_busybox_install_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E env
    ${_busybox_env}
    "${STAGE0_MAKE_PROGRAM}"
    ${_busybox_make_args}
    ${_busybox_verbose_args}
    "CONFIG_PREFIX=${STAGE0_ROOTFS_DIR}"
    install
  COMMAND "${CMAKE_COMMAND}" -E touch "${_busybox_install_stamp}"
  DEPENDS "${STAGE0_BUSYBOX_BUILD_DIR}/busybox" "${_sysroot_stage_stamp}"
  COMMENT "Installing BusyBox into ${STAGE0_ROOTFS_DIR}"
  USES_TERMINAL
  VERBATIM)

add_custom_target(stage0-llvm-runtimes DEPENDS "${_llvm_runtime_layout_stamp}")
add_custom_target(stage0-busybox-config DEPENDS "${STAGE0_BUSYBOX_BUILD_DIR}/.config")
add_custom_target(stage0-busybox-binary DEPENDS "${STAGE0_BUSYBOX_BUILD_DIR}/busybox")
add_custom_target(stage0-busybox-rootfs ALL DEPENDS "${_busybox_install_stamp}")

message(STATUS "stage0 target triple      : ${STAGE0_TARGET_TRIPLE}")
message(STATUS "stage0 host arch          : ${CMAKE_HOST_SYSTEM_PROCESSOR}")
message(STATUS "stage0 clang root         : ${STAGE0_CLANG_ROOT}")
message(STATUS "stage0 llvm archive       : ${STAGE0_LLVM_ARCHIVE}")
message(STATUS "stage0 llvm source        : ${STAGE0_LLVM_SOURCE_DIR}")
message(STATUS "stage0 llvm runtimes      : ${STAGE0_LLVM_RUNTIME_COMPONENTS}")
message(STATUS "stage0 llvm lib source    : ${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}")
message(STATUS "stage0 clang resource dir : ${STAGE0_HOST_CLANG_RESOURCE_DIR}")
message(STATUS "stage0 target resource dir: ${STAGE0_TARGET_RESOURCE_DIR}")
message(STATUS "stage0 target crt dir     : ${STAGE0_TARGET_CRT_DIR}")
message(STATUS "stage0 host arch          : ${STAGE0_HOST_ARCH}")
message(STATUS "stage0 root lib dirs      : ${_stage0_runtime_root_libdirs}")
message(STATUS "stage0 usr lib dirs       : ${_stage0_runtime_usr_libdirs}")
message(STATUS "stage0 cxx rt uses crt    : ${_stage0_cxx_runtimes_use_compiler_rt}")
message(STATUS "stage0 libcxxabi tls dtor : ${_stage0_cxa_thread_atexit_value}")
message(STATUS "stage0 cxx phase runtimes : ${_stage0_cxx_phase_runtime_components_value}")
message(STATUS "stage0 runtime lib search : ${STAGE0_LLVM_RUNTIMES_TRIPLE_LIBDIR}")
message(STATUS "stage0 verbose build      : ${STAGE0_VERBOSE_BUILD}")
message(STATUS "stage0 target sysroot     : ${STAGE0_TARGET_SYSROOT_DIR}")
message(STATUS "stage0 sysroot archive    : ${STAGE0_SYSROOT_ARCHIVE}")
message(STATUS "stage0 busybox source     : ${STAGE0_BUSYBOX_SOURCE_DIR}")
message(STATUS "stage0 busybox archive    : ${STAGE0_BUSYBOX_ARCHIVE}")
message(STATUS "stage0 busybox fragment   : ${STAGE0_BUSYBOX_CONFIG_FRAGMENT}")
message(STATUS "stage0 output rootfs      : ${STAGE0_ROOTFS_DIR}")
