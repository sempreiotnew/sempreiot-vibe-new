# siot_board_def — pin map per model / hw_rev, generated from the repo-root
# tools/pinmap/pinmap.yaml at configure time (brief §2). Layer 1 (platform).
get_filename_component(SIOT_PINMAP_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../tools/pinmap" ABSOLUTE)
set(SIOT_PINMAP_YAML "${SIOT_PINMAP_DIR}/pinmap.yaml")
set(SIOT_PINMAP_GEN  "${SIOT_PINMAP_DIR}/gen_board_def.py")
set(SIOT_BOARD_DEF_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/gen")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${SIOT_PINMAP_YAML}" "${SIOT_PINMAP_GEN}")

idf_build_get_property(_siot_python PYTHON)
execute_process(COMMAND ${_siot_python} "${SIOT_PINMAP_GEN}" "${SIOT_PINMAP_YAML}"
                        "${SIOT_BOARD_DEF_GEN_DIR}/siot_board_def_gen.h"
                RESULT_VARIABLE _siot_pinmap_rc
                ERROR_VARIABLE _siot_pinmap_err)
if(NOT _siot_pinmap_rc EQUAL 0)
    message(FATAL_ERROR "gen_board_def.py failed:\n${_siot_pinmap_err}")
endif()

idf_component_register(SRCS "src/siot_board_def.c"
                       INCLUDE_DIRS "include"
                       PRIV_INCLUDE_DIRS "${SIOT_BOARD_DEF_GEN_DIR}")
