if(NOT DEFINED ROOTFS_DIR)
  message(FATAL_ERROR "ROOTFS_DIR is required")
endif()

if(NOT DEFINED SOURCE_LIBDIR)
  message(FATAL_ERROR "SOURCE_LIBDIR is required")
endif()

if(NOT DEFINED GCC_TOOLCHAIN_ROOT)
  message(FATAL_ERROR "GCC_TOOLCHAIN_ROOT is required")
endif()

if(NOT DEFINED TARGET_TRIPLE)
  message(FATAL_ERROR "TARGET_TRIPLE is required")
endif()

if(NOT DEFINED GCC_TOOLCHAIN_VERSION)
  message(FATAL_ERROR "GCC_TOOLCHAIN_VERSION is required")
endif()

if(NOT EXISTS "${SOURCE_LIBDIR}")
  message(FATAL_ERROR "LLVM runtime source directory does not exist: ${SOURCE_LIBDIR}")
endif()

if(NOT DEFINED ROOT_SHARED_LIB_DIRS)
  set(ROOT_SHARED_LIB_DIRS "")
endif()

set(_gcc_libdir "${GCC_TOOLCHAIN_ROOT}/lib/gcc/${TARGET_TRIPLE}/${GCC_TOOLCHAIN_VERSION}")

function(stage0_overlay_link source_file dest_file)
  if(NOT EXISTS "${source_file}")
    message(FATAL_ERROR "Overlay source file does not exist: ${source_file}")
  endif()

  get_filename_component(_dest_dir "${dest_file}" DIRECTORY)
  file(MAKE_DIRECTORY "${_dest_dir}")
  file(REMOVE "${dest_file}")
  file(RELATIVE_PATH _rel_target "${_dest_dir}" "${source_file}")
  file(CREATE_LINK "${_rel_target}" "${dest_file}" SYMBOLIC)
endfunction()

set(_crtbegin_source "${SOURCE_LIBDIR}/clang_rt.crtbegin.o")
set(_crtend_source "${SOURCE_LIBDIR}/clang_rt.crtend.o")
set(_builtins_source "${SOURCE_LIBDIR}/libclang_rt.builtins.a")

foreach(_crtbegin_name IN ITEMS crtbegin.o crtbeginS.o crtbeginT.o)
  stage0_overlay_link("${_crtbegin_source}" "${_gcc_libdir}/${_crtbegin_name}")
endforeach()

foreach(_crtend_name IN ITEMS crtend.o crtendS.o)
  stage0_overlay_link("${_crtend_source}" "${_gcc_libdir}/${_crtend_name}")
endforeach()

foreach(_libgcc_name IN ITEMS libgcc.a libgcc_eh.a)
  stage0_overlay_link("${_builtins_source}" "${_gcc_libdir}/${_libgcc_name}")
endforeach()

set(_libgcc_shared_candidates "")
foreach(_root_shared_libdir IN LISTS ROOT_SHARED_LIB_DIRS)
  foreach(_libgcc_shared_name IN ITEMS libgcc_s.so.1 libgcc_s.so)
    if(EXISTS "${ROOTFS_DIR}/${_root_shared_libdir}/${_libgcc_shared_name}")
      list(APPEND _libgcc_shared_candidates
        "${ROOTFS_DIR}/${_root_shared_libdir}/${_libgcc_shared_name}")
    endif()
  endforeach()
endforeach()

list(REMOVE_DUPLICATES _libgcc_shared_candidates)
foreach(_libgcc_shared_candidate IN LISTS _libgcc_shared_candidates)
  get_filename_component(_libgcc_shared_name "${_libgcc_shared_candidate}" NAME)
  stage0_overlay_link("${_libgcc_shared_candidate}" "${_gcc_libdir}/${_libgcc_shared_name}")
endforeach()
