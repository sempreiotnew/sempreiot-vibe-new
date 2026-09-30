# siot_ota_board — the board's side of a firmware push (protocol §13.3, OTA
# brief step 1): receives an image from the tablet, checks it, installs its own
# or stores a node / leaf image in fw_store; self-test and rollback of a new
# board image. Layer 4 (features). Board only: the node and the leaf never
# call it, the linker drops it from their images.
idf_component_register(SRCS "src/siot_ota_board.c" "src/ota_rollout.c" "src/ota_server.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES app_update bootloader_support esp_partition esp_app_format
                                     esp_timer esp_system esp_http_server fatfs wear_levelling mbedtls nvs_flash
                                     siot_safr siot_ota_proto siot_util siot_evbus siot_version
                                     siot_identity siot_config siot_link siot_coordinator siot_devtab)
