# siot_config — runtime NVS namespace "siot_inst": the installation code,
# name/zone, enrolled list, boot_ctr, dev_seq. Layer 1.
idf_component_register(SRCS "src/siot_config.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES nvs_flash)
