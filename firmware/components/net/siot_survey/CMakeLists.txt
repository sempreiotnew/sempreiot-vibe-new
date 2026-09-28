# siot_survey — PARENT_PROBE / PARENT_OFFER over ESP-NOW (spec §7.14/§7.15):
# the range test of installation-lifecycle-v1.md §6 (survey, purpose 1) and
# the leaf parent-discovery hook (purpose 0, Phase 2 leaves). Layer 2 (net).
# On the node ESP-NOW belongs to Mesh-Lite (it owns esp_now_init and the one
# receive callback), so frames go through esp_mesh_lite_espnow_* with our own
# data type; the board (no Mesh-Lite) uses esp_now directly with the same
# one-byte type prefix so both sides interoperate.
idf_component_register(SRCS "src/siot_survey.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_safr
                       PRIV_REQUIRES esp_wifi esp_timer siot_evbus siot_util)
idf_component_optional_requires(PRIVATE espressif__mesh_lite)
