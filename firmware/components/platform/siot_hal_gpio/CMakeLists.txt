# siot_hal_gpio — thin wrapper over driver/gpio.h for the Phase 1 input pins. Layer 1.
idf_component_register(SRCS "src/siot_hal_gpio.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_driver_gpio)
