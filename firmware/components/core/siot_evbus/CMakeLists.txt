# siot_evbus — esp_event wrapper: one event base, typed event ids. Layer 0.
# esp_event builds for the linux target too (it requires "linux" there).
idf_component_register(SRCS "src/siot_evbus.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_event)
