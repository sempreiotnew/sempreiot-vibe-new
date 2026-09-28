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

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(sempreiot-leaf)
