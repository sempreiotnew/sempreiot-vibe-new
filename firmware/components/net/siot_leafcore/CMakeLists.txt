# siot_leafcore — the battery leaf's runtime (protocol §12): ESP-NOW transport
# with the Mesh-Lite type byte, wake cycle, parent discovery, the leaf ACK,
# mailbox drain, outbox, button verdict, setup window, deep sleep. Layer 2.
# Pure pieces live in core/siot_leaf_proto (host-tested); this file is the IDF glue.
idf_component_register(SRCS "src/siot_leafcore.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_config
                       PRIV_REQUIRES esp_wifi esp_netif esp_event esp_timer esp_hw_support esp_driver_gpio
                                     nvs_flash esp_system
                                     siot_safr siot_leaf_proto siot_util siot_evbus siot_identity
                                     siot_board_def siot_hal_gpio siot_ui_led siot_sensor siot_provisioning
                                     siot_version)
