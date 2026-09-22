# Thin app: app_main() wires components in the boot order of brief §3. No logic here.
idf_component_register(SRCS "app_main.c"
                       PRIV_REQUIRES nvs_flash esp_system siot_version)
