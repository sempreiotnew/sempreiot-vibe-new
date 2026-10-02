# siot_ota_pull — the pull of a firmware image from the board and the record of
# what was installed, shared by the node's and the leaf's OTA clients (protocol
# §13.4, §13.5). Layer 4 (features). No mesh, no frames, no sleep.
idf_component_register(SRCS "src/siot_ota_pull.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_ota_proto
                       PRIV_REQUIRES app_update esp_app_format esp_http_client esp_system mbedtls nvs_flash
                                     siot_version)
