# sempreiot-board — control unit image (8 MB). Thin project: app_main.c only;
# every behaviour lives in ../../components (brief §2). Ported from pocs/board.
cmake_minimum_required(VERSION 3.16)

# Layered component dirs, dependencies point downwards only (brief §2).
set(SIOT_COMPONENTS "${CMAKE_CURRENT_LIST_DIR}/../../components")
list(APPEND EXTRA_COMPONENT_DIRS
     "${SIOT_COMPONENTS}/core"
     "${SIOT_COMPONENTS}/platform"
     "${SIOT_COMPONENTS}/net"
     "${SIOT_COMPONENTS}/ui"
     "${SIOT_COMPONENTS}/features")

# firmware/VERSION is the single source of the version string (brief §2):
# it becomes esp_app_desc_t.version (checked by OTA, §4.3 of the OTA blueprint)
# and siot_version's string. Never type a version anywhere else.
# (siot_version registers the file as a configure dependency; doing it here
# too, under a second spelling of the path, makes ninja see a duplicate output.)
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/../../VERSION" PROJECT_VER LIMIT_COUNT 1)
string(STRIP "${PROJECT_VER}" PROJECT_VER)

# Every image is signed (stage 1, OTA brief decision 8); the key lives outside
# the repository — docs/ota/signing-key.md.
include("${CMAKE_CURRENT_LIST_DIR}/../../tools/cmake/siot_signing.cmake")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(sempreiot-board)
