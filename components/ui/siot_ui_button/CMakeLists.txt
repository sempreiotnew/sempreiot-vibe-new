# siot_ui_button — RST/TEST button: tap / double tap / 5 s hold → bus events. Layer 2 (ui).
idf_component_register(SRCS "src/siot_ui_button.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_evbus
                       PRIV_REQUIRES siot_board_def siot_hal_gpio siot_config esp_timer)
