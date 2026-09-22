# test/host — Unity tests for components/core on the ESP-IDF linux target.
#   idf.py --preview set-target linux && idf.py build && ./build/host_tests.elf
# MINIMAL_BUILD keeps the build to main + what it requires (unity, core, mbedtls).
cmake_minimum_required(VERSION 3.16)

list(APPEND EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_LIST_DIR}/../../components/core"
                                 "${CMAKE_CURRENT_LIST_DIR}/../../components/net")   # siot_provisioning: crypto only on linux

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
idf_build_set_property(MINIMAL_BUILD ON)

# Apple clang >= 17 promotes -Wuninitialized-const-pointer to an error under
# IDF's -Werror inside IDF's OWN mbedtls/library/x509_crt.c (X.509 parsing is
# hardwired on in esp_config.h, so it cannot be excluded). Keep it a warning on
# macOS hosts; GCC on Linux CI ignores the unknown -Wno-error= spelling.
if(APPLE)
    idf_build_set_property(COMPILE_OPTIONS "-Wno-error=uninitialized-const-pointer" APPEND)
endif()
project(host_tests)
