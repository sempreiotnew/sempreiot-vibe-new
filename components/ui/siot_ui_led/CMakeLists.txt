# siot_ui_led — RGB LED pattern engine driven by bus events. Layer 2 (ui).
idf_component_register(SRCS "src/siot_ui_led.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_evbus
                       PRIV_REQUIRES siot_safr siot_board_def siot_hal_pwm esp_timer)
