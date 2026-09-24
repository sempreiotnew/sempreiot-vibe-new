# siot_devtab — the board's device table (installation-lifecycle-v1.md §3):
# one persisted entry per MAC in NVS namespace "siot_devtab" of the ordinary
# "nvs" partition, discovered from authenticated traffic and annotated by
# the tablet. Replaces the ≤ 8 enrolled list. Layer 1 (platform), board only.
idf_component_register(SRCS "src/siot_devtab.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_config
                       PRIV_REQUIRES nvs_flash siot_util siot_safr)
