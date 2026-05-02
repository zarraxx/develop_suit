if(NOT DEFINED ROOTFS_DIR)
  message(FATAL_ERROR "ROOTFS_DIR is required")
endif()

if(NOT DEFINED SOURCE_LIBDIR)
  message(FATAL_ERROR "SOURCE_LIBDIR is required")
endif()

if(NOT EXISTS "${SOURCE_LIBDIR}")
  message(FATAL_ERROR "LLVM runtime source directory does not exist: ${SOURCE_LIBDIR}")
endif()

if(NOT DEFINED ROOT_SHARED_LIB_DIRS)
  set(ROOT_SHARED_LIB_DIRS "")
endif()

if(NOT DEFINED USR_DEV_LIB_DIRS)
  set(USR_DEV_LIB_DIRS "")
endif()

function(stage0_link_into_dir source_file root_dir relative_dir)
  set(_dest_dir "${root_dir}/${relative_dir}")
  get_filename_component(_name "${source_file}" NAME)
  set(_dest_path "${_dest_dir}/${_name}")

  file(MAKE_DIRECTORY "${_dest_dir}")
  file(REMOVE "${_dest_path}")
  file(RELATIVE_PATH _rel_target "${_dest_dir}" "${source_file}")
  file(CREATE_LINK "${_rel_target}" "${_dest_path}" SYMBOLIC)
endfunction()

file(GLOB _runtime_entries LIST_DIRECTORIES FALSE "${SOURCE_LIBDIR}/*")

foreach(_runtime_entry IN LISTS _runtime_entries)
  get_filename_component(_runtime_name "${_runtime_entry}" NAME)

  if(_runtime_name MATCHES "\\.so($|\\.)")
    foreach(_runtime_root_libdir IN LISTS ROOT_SHARED_LIB_DIRS)
      stage0_link_into_dir("${_runtime_entry}" "${ROOTFS_DIR}" "${_runtime_root_libdir}")
    endforeach()
    foreach(_runtime_usr_libdir IN LISTS USR_DEV_LIB_DIRS)
      stage0_link_into_dir("${_runtime_entry}" "${ROOTFS_DIR}" "${_runtime_usr_libdir}")
    endforeach()
  elseif(_runtime_name MATCHES "\\.(a|o)$")
    foreach(_runtime_usr_libdir IN LISTS USR_DEV_LIB_DIRS)
      stage0_link_into_dir("${_runtime_entry}" "${ROOTFS_DIR}" "${_runtime_usr_libdir}")
    endforeach()
  endif()
endforeach()
