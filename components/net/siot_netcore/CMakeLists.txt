# siot_netcore — node side: emitter, fast-retry, re-announce, downlink
# dispatch, states (brief §5.3, §9). From pocs/node/main/node_safr.c. Layer 2.
idf_component_register(SRCS "src/siot_netcore.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_timer siot_safr siot_util siot_evbus siot_config siot_identity siot_link)
