# siot_coordinator — board side: root duties, device table, journal,
# INSTALLATION / DEVICE_TABLE, lifecycle commands, HEARTBEAT/TOPOLOGY shim
# (brief §8, installation-lifecycle-v1.md §3). From pocs/board/main/root_duties.c,
# installation_msg.c, board_state.h. Layer 2.
idf_component_register(SRCS "src/siot_coordinator.c" "src/coord_installation.c" "src/coord_devtable.c" "src/coord_setup.c" "src/coord_admin.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_timer siot_safr siot_util siot_evbus siot_config siot_identity siot_link
                                     siot_devtab siot_survey siot_provisioning esp_system)
