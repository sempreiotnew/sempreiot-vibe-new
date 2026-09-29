# siot_version — firmware version string + build id.
# Both are resolved at CMake configure time: the version from firmware/VERSION
# (the only place it is written, brief §2), the build id from the git commit of
# the firmware repo. The values land in a generated header in the build dir so
# no source file ever contains a version literal.
get_filename_component(SIOT_VERSION_FILE "${CMAKE_CURRENT_LIST_DIR}/../../../VERSION" ABSOLUTE)
file(STRINGS "${SIOT_VERSION_FILE}" SIOT_VERSION_STRING LIMIT_COUNT 1)
string(STRIP "${SIOT_VERSION_STRING}" SIOT_VERSION_STRING)
if(DEFINED ENV{SIOT_VERSION} AND NOT "$ENV{SIOT_VERSION}" STREQUAL "")
    set(SIOT_VERSION_STRING "$ENV{SIOT_VERSION}") # bench test images: tools/ota_test_images.sh
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${SIOT_VERSION_FILE}")

find_package(Git QUIET)
set(SIOT_BUILD_ID "nogit")
if(GIT_FOUND)
    execute_process(COMMAND ${GIT_EXECUTABLE} -C "${CMAKE_CURRENT_LIST_DIR}" rev-parse --short=8 HEAD
                    OUTPUT_VARIABLE _siot_git_rev OUTPUT_STRIP_TRAILING_WHITESPACE
                    RESULT_VARIABLE _siot_git_rc ERROR_QUIET)
    if(_siot_git_rc EQUAL 0)
        execute_process(COMMAND ${GIT_EXECUTABLE} -C "${CMAKE_CURRENT_LIST_DIR}" status --porcelain
                        OUTPUT_VARIABLE _siot_git_dirty OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        set(SIOT_BUILD_ID "${_siot_git_rev}")
        if(NOT "${_siot_git_dirty}" STREQUAL "")
            set(SIOT_BUILD_ID "${SIOT_BUILD_ID}-dirty")
        endif()
    endif()
endif()

set(SIOT_VERSION_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/gen")
configure_file("${CMAKE_CURRENT_LIST_DIR}/src/siot_version_gen.h.in"
               "${SIOT_VERSION_GEN_DIR}/siot_version_gen.h" @ONLY)

idf_component_register(SRCS "src/siot_version.c"
                       INCLUDE_DIRS "include"
                       PRIV_INCLUDE_DIRS "${SIOT_VERSION_GEN_DIR}")
