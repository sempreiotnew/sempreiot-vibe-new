idf_component_register(SRCS "siot_led.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_driver_ledc esp_timer)
