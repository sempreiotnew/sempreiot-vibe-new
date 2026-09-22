# siot_identity — factory identity from the read-only nvs_factory partition. Layer 1.
idf_component_register(SRCS "src/siot_identity.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES nvs_flash esp_hw_support)
