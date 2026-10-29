# siot_labels — the board's zone and endereçamento tables (protocol §14.1,
# v3.8): {id, name} behind the names the tablet shows, one NVS blob per kind in
# namespace "siot_labels" of the ordinary "nvs" partition. Layer 1 (platform),
# board only.
idf_component_register(SRCS "src/siot_labels.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_safr
                       PRIV_REQUIRES nvs_flash)
