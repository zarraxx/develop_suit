if(NOT DEFINED INPUT OR INPUT STREQUAL "")
  message(FATAL_ERROR "StagePythonPatchLibiconvConfig.cmake requires -DINPUT=/path/to/config.h")
endif()

if(NOT EXISTS "${INPUT}")
  message(FATAL_ERROR "libiconv config.h does not exist: ${INPUT}")
endif()

file(READ "${INPUT}" _stage_python_libiconv_config_h)

function(_stage_python_libiconv_replace_define macro value)
  set(_pattern "/* #undef ${macro} */")
  set(_replacement "#define ${macro}${value}")
  string(REPLACE "${_pattern}" "${_replacement}" _stage_python_libiconv_config_h "${_stage_python_libiconv_config_h}")
  set(_stage_python_libiconv_config_h "${_stage_python_libiconv_config_h}" PARENT_SCOPE)
endfunction()

foreach(_macro IN ITEMS
    ENABLE_NLS
    HAVE_ALLOCA
    HAVE_ALLOCA_H
    HAVE_CANONICALIZE_FILE_NAME
    HAVE_DCGETTEXT
    HAVE_DLFCN_H
    HAVE_ENVIRON_DECL
    HAVE_ERROR
    HAVE_ERROR_H
    HAVE_FCNTL
    HAVE_FEATURES_H
    HAVE_GETC_UNLOCKED
    HAVE_GETDTABLESIZE
    HAVE_GETTEXT
    HAVE_ICONV
    HAVE_INTTYPES_H
    HAVE_LANGINFO_CODESET
    HAVE_LIMITS_H
    HAVE_LONG_LONG_INT
    HAVE_LSTAT
    HAVE_MALLOC_0_NONNULL
    HAVE_MALLOC_POSIX
    HAVE_MALLOC_PTRDIFF
    HAVE_MBRTOWC
    HAVE_MBSINIT
    HAVE_MEMMOVE
    HAVE_MINMAX_IN_SYS_PARAM_H
    HAVE_PTHREAD_API
    HAVE_PTHREAD_H
    HAVE_PTHREAD_SPINLOCK_T
    HAVE_PTHREAD_T
    HAVE_READLINK
    HAVE_REALPATH
    HAVE_SCHED_H
    HAVE_SETENV
    HAVE_SETLOCALE
    HAVE_SIGSET_T
    HAVE_STDBOOL_H
    HAVE_STDCKDINT_H
    HAVE_STDINT_H
    HAVE_STDIO_H
    HAVE_STDLIB_H
    HAVE_STRERROR_R
    HAVE_STRINGS_H
    HAVE_STRING_H
    HAVE_SYMLINK
    HAVE_SYS_PARAM_H
    HAVE_SYS_SOCKET_H
    HAVE_SYS_STAT_H
    HAVE_SYS_TIME_H
    HAVE_SYS_TYPES_H
    HAVE_UNISTD_H
    HAVE_UNSIGNED_LONG_LONG_INT
    HAVE_WCHAR_H
    HAVE_WCRTOMB
    HAVE_WEAK_SYMBOLS
    HAVE_WINT_T
    HAVE_WORKING_O_DIRECTORY
    HAVE_WORKING_O_NOATIME
    HAVE_WORKING_O_NOFOLLOW
    HAVE_XLOCALE_H
    STDC_HEADERS)
  _stage_python_libiconv_replace_define("${_macro}" " 1")
endforeach()

foreach(_macro IN ITEMS
    HAVE_DECL_CLEARERR_UNLOCKED
    HAVE_DECL_ECVT
    HAVE_DECL_EXECVPE
    HAVE_DECL_FCLOSEALL
    HAVE_DECL_FCVT
    HAVE_DECL_FEOF_UNLOCKED
    HAVE_DECL_FERROR_UNLOCKED
    HAVE_DECL_FFLUSH_UNLOCKED
    HAVE_DECL_FGETS_UNLOCKED
    HAVE_DECL_FILENO_UNLOCKED
    HAVE_DECL_FPUTC_UNLOCKED
    HAVE_DECL_FPUTS_UNLOCKED
    HAVE_DECL_FREAD_UNLOCKED
    HAVE_DECL_FWRITE_UNLOCKED
    HAVE_DECL_GCVT
    HAVE_DECL_GETCHAR_UNLOCKED
    HAVE_DECL_GETC_UNLOCKED
    HAVE_DECL_GETDTABLESIZE
    HAVE_DECL_GETW
    HAVE_DECL_MEMEQ
    HAVE_DECL_PUTCHAR_UNLOCKED
    HAVE_DECL_PUTC_UNLOCKED
    HAVE_DECL_PUTW
    HAVE_DECL_SETENV
    HAVE_DECL_STREQ
    HAVE_DECL_STRERROR_R
    HAVE_DECL_WCSDUP)
  _stage_python_libiconv_replace_define("${_macro}" " 1")
endforeach()

foreach(_macro IN ITEMS
    HAVE_DECL__PUTENV)
  _stage_python_libiconv_replace_define("${_macro}" " 0")
endforeach()

_stage_python_libiconv_replace_define("ICONV_CONST" "")
_stage_python_libiconv_replace_define("INSTALLPREFIX" " \"/usr\"")
_stage_python_libiconv_replace_define("LT_OBJDIR" " \".libs/\"")
_stage_python_libiconv_replace_define("PACKAGE" " \"libiconv\"")
_stage_python_libiconv_replace_define("PACKAGE_BUGREPORT" " \"\"")
_stage_python_libiconv_replace_define("PACKAGE_NAME" " \"libiconv\"")
_stage_python_libiconv_replace_define("PACKAGE_STRING" " \"libiconv 1.19\"")
_stage_python_libiconv_replace_define("PACKAGE_TARNAME" " \"libiconv\"")
_stage_python_libiconv_replace_define("PACKAGE_URL" " \"\"")
_stage_python_libiconv_replace_define("PACKAGE_VERSION" " \"1.19\"")
_stage_python_libiconv_replace_define("VERSION" " \"1.19\"")

file(WRITE "${INPUT}" "${_stage_python_libiconv_config_h}")
