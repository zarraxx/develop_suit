if(NOT DEFINED ROOTFS_DIR)
  message(FATAL_ERROR "ROOTFS_DIR is required")
endif()

if(NOT DEFINED TARGET_TRIPLE)
  message(FATAL_ERROR "TARGET_TRIPLE is required")
endif()

set(_etc_dir "${ROOTFS_DIR}/etc")
set(_conf_d_dir "${_etc_dir}/ld.so.conf.d")
set(_main_conf "${_etc_dir}/ld.so.conf")
set(_stage1_conf "${_conf_d_dir}/stage1.conf")
set(_include_line "include /etc/ld.so.conf.d/*.conf")

file(MAKE_DIRECTORY "${_etc_dir}")
file(MAKE_DIRECTORY "${_conf_d_dir}")

file(WRITE "${_stage1_conf}"
  "/lib\n"
  "/lib64\n"
  "/usr/lib\n"
  "/usr/lib64\n"
  "/usr/lib/${TARGET_TRIPLE}\n")

if(EXISTS "${_main_conf}")
  file(READ "${_main_conf}" _main_conf_contents)
  string(FIND "${_main_conf_contents}" "${_include_line}" _include_pos)
  if(_include_pos EQUAL -1)
    string(APPEND _main_conf_contents "\n${_include_line}\n")
    file(WRITE "${_main_conf}" "${_main_conf_contents}")
  endif()
else()
  file(WRITE "${_main_conf}" "${_include_line}\n")
endif()
