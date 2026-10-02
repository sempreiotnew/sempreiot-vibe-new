# siot_ota_node — a mains unit takes a firmware offer (protocol §13.4, OTA brief
# step 2): pulls the image from the board (siot_ota_pull), restarts into it,
# tests itself, confirms or goes back, and reports. Layer 4 (features).
# Node image only.
idf_component_register(SRCS "src/siot_ota_node.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES app_update esp_timer esp_system
                                     siot_safr siot_ota_proto siot_ota_pull siot_util siot_evbus siot_version
                                     siot_netcore siot_link)
