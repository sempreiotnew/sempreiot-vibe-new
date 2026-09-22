# siot_hal_pwm — thin wrapper over driver/ledc.h for the RGB LED. Layer 1.
idf_component_register(SRCS "src/siot_hal_pwm.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_driver_ledc)
