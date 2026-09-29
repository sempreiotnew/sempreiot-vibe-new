# sempreiot-leaf — the battery detector (4 MB, N4). Thin project: app_main.c only;
# every behaviour lives in ../../components (brief §2). No Mesh-Lite: a leaf never
# joins a mesh (protocol §12.1), so the image carries esp_wifi + esp_now only.
cmake_minimum_required(VERSION 3.16)

set(SIOT_COMPONENTS "${CMAKE_CURRENT_LIST_DIR}/../../components")
list(APPEND EXTRA_COMPONENT_DIRS
     "${SIOT_COMPONENTS}/core"
     "${SIOT_COMPONENTS}/platform"
     "${SIOT_COMPONENTS}/net"
     "${SIOT_COMPONENTS}/ui"
     "${SIOT_COMPONENTS}/features")

# firmware/VERSION is the single source of the version string (see apps/node).
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/../../VERSION" PROJECT_VER LIMIT_COUNT 1)
string(STRIP "${PROJECT_VER}" PROJECT_VER)
# Bench only (tools/ota_test_images.sh): another version for a test image,
# without touching firmware/VERSION. Read at configure time.
if(DEFINED ENV{SIOT_VERSION} AND NOT "$ENV{SIOT_VERSION}" STREQUAL "")
    set(PROJECT_VER "$ENV{SIOT_VERSION}")
    message(WARNING "SIOT_VERSION is set: this image says it is ${PROJECT_VER}, not firmware/VERSION")
endif()

# Every image is signed (stage 1, OTA brief decision 8); the key lives outside
# the repository — docs/ota/signing-key.md.
include("${CMAKE_CURRENT_LIST_DIR}/../../tools/cmake/siot_signing.cmake")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(sempreiot-leaf)
