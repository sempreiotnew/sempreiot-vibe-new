# siot_leafmgr — the AC node's parent role for battery leafs (protocol §12.11):
# leaf ACK (9 bytes), custody of leaf events up to the board, mailbox for a
# sleeping leaf, ESP-NOW delivery. Phase 2 feature (features/README.md):
# talks to the system only through siot_survey / siot_netcore / siot_link hooks.
idf_component_register(SRCS "src/siot_leafmgr.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_wifi esp_timer siot_safr siot_leaf_proto siot_ota_proto siot_util siot_config
                                     siot_survey siot_netcore siot_link siot_evbus)
