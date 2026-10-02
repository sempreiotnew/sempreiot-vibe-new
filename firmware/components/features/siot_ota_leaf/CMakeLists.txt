# siot_ota_leaf — a battery unit takes a firmware offer that rode its parent's
# HEARTBEAT ACK (protocol §13.5, OTA brief step 4): answers it, pulls the
# image as a station on the parent's SoftAP (siot_ota_pull), sleeps, and tests
# itself on the next wake. Layer 4 (features). Leaf image only.
idf_component_register(SRCS "src/siot_ota_leaf.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_leaf_proto siot_ota_proto
                       PRIV_REQUIRES app_update esp_event esp_timer esp_wifi
                                     siot_ota_pull siot_safr siot_util siot_version)
