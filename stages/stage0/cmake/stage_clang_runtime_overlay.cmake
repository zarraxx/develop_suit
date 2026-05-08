if(NOT DEFINED CLANG_RESOURCE_DIR)
  message(FATAL_ERROR "CLANG_RESOURCE_DIR is required")
endif()

if(NOT DEFINED HOST_CLANG_RESOURCE_DIR)
  message(FATAL_ERROR "HOST_CLANG_RESOURCE_DIR is required")
endif()

if(NOT DEFINED BUILTINS_SOURCE)
  message(FATAL_ERROR "BUILTINS_SOURCE is required")
endif()

if(NOT DEFINED BUILTINS_RELATIVE_PATH)
  message(FATAL_ERROR "BUILTINS_RELATIVE_PATH is required")
endif()

if(NOT DEFINED CRT_DIR)
  message(FATAL_ERROR "CRT_DIR is required")
endif()

if(NOT DEFINED CRTBEGIN_SOURCE)
  message(FATAL_ERROR "CRTBEGIN_SOURCE is required")
endif()

if(NOT DEFINED CRTEND_SOURCE)
  message(FATAL_ERROR "CRTEND_SOURCE is required")
endif()

foreach(_required_path IN ITEMS
    "${HOST_CLANG_RESOURCE_DIR}"
    "${BUILTINS_SOURCE}"
    "${CRTBEGIN_SOURCE}"
    "${CRTEND_SOURCE}")
  if(NOT EXISTS "${_required_path}")
    message(FATAL_ERROR "Required overlay input does not exist: ${_required_path}")
  endif()
endforeach()

function(stage0_overlay_link source_file dest_file)
  get_filename_component(_dest_dir "${dest_file}" DIRECTORY)
  file(MAKE_DIRECTORY "${_dest_dir}")
  file(REMOVE "${dest_file}")
  file(RELATIVE_PATH _rel_target "${_dest_dir}" "${source_file}")
  file(CREATE_LINK "${_rel_target}" "${dest_file}" SYMBOLIC)
endfunction()

file(REMOVE_RECURSE "${CLANG_RESOURCE_DIR}")
file(MAKE_DIRECTORY "${CLANG_RESOURCE_DIR}")

if(EXISTS "${HOST_CLANG_RESOURCE_DIR}/include")
  stage0_overlay_link("${HOST_CLANG_RESOURCE_DIR}/include" "${CLANG_RESOURCE_DIR}/include")
endif()

set(_builtins_dest "${CLANG_RESOURCE_DIR}/${BUILTINS_RELATIVE_PATH}")
stage0_overlay_link("${BUILTINS_SOURCE}" "${_builtins_dest}")

foreach(_crtbegin_name IN ITEMS crtbegin.o crtbeginS.o crtbeginT.o)
  stage0_overlay_link("${CRTBEGIN_SOURCE}" "${CRT_DIR}/${_crtbegin_name}")
endforeach()

foreach(_crtend_name IN ITEMS crtend.o crtendS.o)
  stage0_overlay_link("${CRTEND_SOURCE}" "${CRT_DIR}/${_crtend_name}")
endforeach()
