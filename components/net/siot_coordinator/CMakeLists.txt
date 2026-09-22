# siot_coordinator — board side: root duties, children/enrolled tables,
# journal, INSTALLATION, HEARTBEAT/TOPOLOGY shim (brief §8). From
# pocs/board/main/root_duties.c, installation_msg.c, board_state.h. Layer 2.
idf_component_register(SRCS "src/siot_coordinator.c" "src/coord_installation.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_timer siot_safr siot_util siot_evbus siot_config siot_identity siot_link)
