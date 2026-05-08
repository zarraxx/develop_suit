include_guard(GLOBAL)

include(CMakeParseArguments)

function(stage_python_archive_stem input_path out_var)
  get_filename_component(_name "${input_path}" NAME)
  string(REGEX REPLACE "\\.(tar\\.(gz|bz2|xz)|tgz|tbz2|txz)$" "" _stem "${_name}")
  set(${out_var} "${_stem}" PARENT_SCOPE)
endfunction()

function(stage_python_try_pick_single_file out_var description)
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
  endif()
  if(_count GREATER 1)
    message(FATAL_ERROR
      "Found multiple candidates for ${description}: ${_matches}\n"
      "Please pass an explicit path.")
  endif()
  list(GET _matches 0 _match)
  set(${out_var} "${_match}" PARENT_SCOPE)
endfunction()

function(stage_python_download_file_once output_path url description)
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

function(stage_python_ensure_default_archive out_var description cache_dir archive_name archive_url)
  set(_archive_path "${cache_dir}/${archive_name}")
  if(NOT EXISTS "${_archive_path}")
    if(NOT STAGE_PYTHON_DOWNLOAD_MISSING)
      message(FATAL_ERROR
        "Could not find ${description} at ${_archive_path} and automatic download is disabled.\n"
        "Set STAGE_PYTHON_DOWNLOAD_MISSING=ON, place the archive in cache/, or pass an explicit path.")
    endif()
    stage_python_download_file_once("${_archive_path}" "${archive_url}" "${description}")
  endif()
  set(${out_var} "${_archive_path}" PARENT_SCOPE)
endfunction()

function(stage_python_extract_archive_once archive_path destination_dir)
  if(NOT EXISTS "${archive_path}")
    message(FATAL_ERROR "Archive does not exist: ${archive_path}")
  endif()

  file(SHA256 "${archive_path}" _archive_hash)
  set(_stamp_path "${destination_dir}/.stage-python-extract.sha256")
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

function(stage_python_unwrap_single_subdir root_dir marker_relpath out_var)
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

function(stage_python_resolve_archive_source out_var description cache_dir extract_parent_dir marker_relpath)
  set(options)
  set(oneValueArgs SOURCE_DIR ARCHIVE DEFAULT_ARCHIVE URL SOURCE_SUBDIR)
  set(multiValueArgs GLOB_PATTERNS)
  cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(DEFINED ARG_SOURCE_DIR AND NOT "${ARG_SOURCE_DIR}" STREQUAL "")
    if(NOT EXISTS "${ARG_SOURCE_DIR}/${marker_relpath}")
      message(FATAL_ERROR
        "${description} source tree does not look valid: ${ARG_SOURCE_DIR}\n"
        "Missing marker: ${marker_relpath}")
    endif()
    set(${out_var} "${ARG_SOURCE_DIR}" PARENT_SCOPE)
    return()
  endif()

  set(_archive_path "${ARG_ARCHIVE}")
  if("${_archive_path}" STREQUAL "")
    set(_resolved_archive "")
    if(DEFINED ARG_GLOB_PATTERNS AND NOT "${ARG_GLOB_PATTERNS}" STREQUAL "")
      stage_python_try_pick_single_file(_resolved_archive "${description} archive" ${ARG_GLOB_PATTERNS})
    endif()
    if("${_resolved_archive}" STREQUAL "")
      if(NOT DEFINED ARG_DEFAULT_ARCHIVE OR "${ARG_DEFAULT_ARCHIVE}" STREQUAL ""
          OR NOT DEFINED ARG_URL OR "${ARG_URL}" STREQUAL "")
        message(FATAL_ERROR
          "Could not resolve ${description} archive automatically. "
          "Pass SOURCE_DIR/ARCHIVE or provide DEFAULT_ARCHIVE and URL.")
      endif()
      stage_python_ensure_default_archive(
        _resolved_archive
        "${description} archive"
        "${cache_dir}"
        "${ARG_DEFAULT_ARCHIVE}"
        "${ARG_URL}")
    endif()
    set(_archive_path "${_resolved_archive}")
  endif()

  stage_python_archive_stem("${_archive_path}" _archive_stem)
  set(_extract_dir "${extract_parent_dir}/${_archive_stem}")
  stage_python_extract_archive_once("${_archive_path}" "${_extract_dir}")
  stage_python_unwrap_single_subdir("${_extract_dir}" "${marker_relpath}" _source_root_dir)

  set(_source_dir "${_source_root_dir}")
  if(DEFINED ARG_SOURCE_SUBDIR AND NOT "${ARG_SOURCE_SUBDIR}" STREQUAL "")
    set(_source_dir "${_source_root_dir}/${ARG_SOURCE_SUBDIR}")
    if(NOT EXISTS "${_source_dir}")
      message(FATAL_ERROR
        "${description} source subdir does not exist: ${_source_dir}\n"
        "Archive root was resolved to: ${_source_root_dir}")
    endif()
  endif()

  set(${out_var} "${_source_dir}" PARENT_SCOPE)
endfunction()

function(stage_python_normalize_host_arch input_arch out_var)
  string(TOLOWER "${input_arch}" _arch)
  if(_arch STREQUAL "amd64")
    set(_arch "x86_64")
  elseif(_arch STREQUAL "arm64")
    set(_arch "aarch64")
  endif()
  set(${out_var} "${_arch}" PARENT_SCOPE)
endfunction()

function(stage_python_default_llvm_download_info out_filename_var out_url_var)
  stage_python_normalize_host_arch("${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)
  if(_host_arch STREQUAL "x86_64")
    set(_archive_name "compiler-llvm-18.1.8-linux-x86_64.tar.gz")
    set(_archive_url "${STAGE_PYTHON_LLVM_X86_64_URL}")
  elseif(_host_arch STREQUAL "aarch64")
    set(_archive_name "compiler-llvm-18.1.8-linux-aarch64.tar.gz")
    set(_archive_url "${STAGE_PYTHON_LLVM_AARCH64_URL}")
  else()
    message(FATAL_ERROR
      "Automatic LLVM host toolchain download is not configured for host arch "
      "${CMAKE_HOST_SYSTEM_PROCESSOR}. Set STAGE_PYTHON_LLVM_ARCHIVE or STAGE_PYTHON_CLANG_ROOT explicitly.")
  endif()

  set(${out_filename_var} "${_archive_name}" PARENT_SCOPE)
  set(${out_url_var} "${_archive_url}" PARENT_SCOPE)
endfunction()

function(stage_python_resolve_default_llvm_archive out_var cache_dir)
  stage_python_normalize_host_arch("${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)
  file(GLOB _all_archives LIST_DIRECTORIES FALSE "${cache_dir}/compiler-llvm-*-linux-*.tar.gz")
  if(NOT _all_archives)
    stage_python_default_llvm_download_info(_default_llvm_name _default_llvm_url)
    stage_python_ensure_default_archive(
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
      "Please set STAGE_PYTHON_LLVM_ARCHIVE explicitly.")
  endif()

  stage_python_default_llvm_download_info(_default_llvm_name _default_llvm_url)
  set(_expected_default_archive "${cache_dir}/${_default_llvm_name}")
  if(EXISTS "${_expected_default_archive}")
    set(${out_var} "${_expected_default_archive}" PARENT_SCOPE)
    return()
  endif()

  if(STAGE_PYTHON_DOWNLOAD_MISSING)
    stage_python_ensure_default_archive(
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
    "Set STAGE_PYTHON_LLVM_ARCHIVE explicitly or enable automatic download.")
endfunction()

function(stage_python_default_host_triple out_var)
  stage_python_normalize_host_arch("${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)
  set(_host_os "linux")
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(_host_os "apple-darwin")
  elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    set(_host_os "unknown-linux-gnu")
  endif()
  set(${out_var} "${_host_arch}-${_host_os}" PARENT_SCOPE)
endfunction()

function(stage_python_detect_build_triple out_var)
  if(DEFINED STAGE_PYTHON_HOST_CONFIG_GUESS
      AND NOT STAGE_PYTHON_HOST_CONFIG_GUESS STREQUAL ""
      AND EXISTS "${STAGE_PYTHON_HOST_CONFIG_GUESS}")
    execute_process(
      COMMAND /bin/sh "${STAGE_PYTHON_HOST_CONFIG_GUESS}"
      RESULT_VARIABLE _stage_python_guess_status
      OUTPUT_VARIABLE _stage_python_guess_output
      ERROR_VARIABLE _stage_python_guess_error
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_STRIP_TRAILING_WHITESPACE)
    if(_stage_python_guess_status EQUAL 0 AND NOT _stage_python_guess_output STREQUAL "")
      set(${out_var} "${_stage_python_guess_output}" PARENT_SCOPE)
      return()
    endif()
  endif()

  stage_python_default_host_triple(_stage_python_default_build_triple)
  set(${out_var} "${_stage_python_default_build_triple}" PARENT_SCOPE)
endfunction()

function(stage_python_get_no_doc_install_commands rootfs_dir install_prefix out_var)
  set(${out_var}
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${rootfs_dir}${install_prefix}/share/doc"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${rootfs_dir}${install_prefix}/share/man"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${rootfs_dir}${install_prefix}/man"
    PARENT_SCOPE)
endfunction()

function(stage_python_collect_triplet_refresh_commands source_dir out_var)
  set(_stage_python_commands "")

  if((NOT DEFINED STAGE_PYTHON_HOST_CONFIG_SUB OR STAGE_PYTHON_HOST_CONFIG_SUB STREQUAL "" OR NOT EXISTS "${STAGE_PYTHON_HOST_CONFIG_SUB}")
      AND (NOT DEFINED STAGE_PYTHON_HOST_CONFIG_GUESS OR STAGE_PYTHON_HOST_CONFIG_GUESS STREQUAL "" OR NOT EXISTS "${STAGE_PYTHON_HOST_CONFIG_GUESS}"))
    set(${out_var} "${_stage_python_commands}" PARENT_SCOPE)
    return()
  endif()

  file(GLOB_RECURSE _stage_python_source_files LIST_DIRECTORIES FALSE "${source_dir}/*")
  foreach(_stage_python_path IN LISTS _stage_python_source_files)
    get_filename_component(_stage_python_name "${_stage_python_path}" NAME)
    if(_stage_python_name STREQUAL "config.sub")
      if(DEFINED STAGE_PYTHON_HOST_CONFIG_SUB AND NOT STAGE_PYTHON_HOST_CONFIG_SUB STREQUAL "" AND EXISTS "${STAGE_PYTHON_HOST_CONFIG_SUB}")
        list(APPEND _stage_python_commands
          COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${STAGE_PYTHON_HOST_CONFIG_SUB}" "${_stage_python_path}")
      endif()
    elseif(_stage_python_name STREQUAL "config.guess")
      if(DEFINED STAGE_PYTHON_HOST_CONFIG_GUESS AND NOT STAGE_PYTHON_HOST_CONFIG_GUESS STREQUAL "" AND EXISTS "${STAGE_PYTHON_HOST_CONFIG_GUESS}")
        list(APPEND _stage_python_commands
          COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${STAGE_PYTHON_HOST_CONFIG_GUESS}" "${_stage_python_path}")
      endif()
    endif()
  endforeach()

  set(${out_var} "${_stage_python_commands}" PARENT_SCOPE)
endfunction()
