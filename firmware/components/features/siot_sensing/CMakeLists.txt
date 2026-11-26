# siot_sensing — heat and humidity rules (protocol §7.1.6, phase 5 brief §4–§6).
# Layer 4 (features).
#
#   src/sensing_rules.c   the rules and the HDC2080 number conversions: pure C,
#                         no IDF header — the only file compiled on the linux
#                         target, covered by test/host (test_sensing.c).
#   src/siot_sensing.c    the mains unit's side: 1 s sampling through
#                         siot_sensor, events through siot_netcore. Node image.
#
# The battery unit's side (wake by the sensor, RTC history) is not written yet:
# it needs the leaf's alarm path first (brief §10 step 5).
set(srcs "src/sensing_rules.c")
set(priv "")
if(NOT "${IDF_TARGET}" STREQUAL "linux")
    list(APPEND srcs "src/siot_sensing.c")
    set(priv esp_timer esp_driver_gpio siot_sensor siot_netcore siot_safr siot_board_def)
endif()
idf_component_register(SRCS ${srcs}
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES ${priv})
