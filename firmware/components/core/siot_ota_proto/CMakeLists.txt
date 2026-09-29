# siot_ota_proto — the firmware-update messages of protocol §13 (v3.5): pure
# codecs and the version rule. No IDF drivers: builds on the linux target and
# is covered by test/host. The transfer, the scheduler and the client that use
# them are other components (OTA brief steps 1 and 2).
idf_component_register(SRCS "src/siot_ota_proto.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_safr siot_util)
