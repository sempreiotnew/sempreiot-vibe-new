# siot_sensor — smoke / temperature / battery readings behind one interface.
# Phase 2 leaf: only the MOCK backend exists (no detector PCB yet); the real
# ADPD188BI / HDC2080 / ADC backend arrives with the sensing phase. Layer 1.
idf_component_register(SRCS "src/siot_sensor.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_timer)
