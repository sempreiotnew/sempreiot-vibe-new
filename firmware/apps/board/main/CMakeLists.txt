# Thin app: app_main() wires components in the boot order of brief §3. No logic here.
idf_component_register(SRCS "app_main.c"
                       PRIV_REQUIRES nvs_flash esp_system esp_timer
                                     siot_version siot_evbus siot_safr
                                     siot_board_def siot_identity siot_config siot_devtab
                                     siot_ui_led siot_ui_button
                                     siot_provisioning siot_link siot_coordinator siot_survey)
