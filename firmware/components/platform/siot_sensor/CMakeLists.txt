# siot_sensor — smoke / temperature / battery readings behind one interface.
# Two backends: MOCK (devkits, scripted values) and the real HDC2080
# temperature / humidity sensor (docs/phases-development/phase5-heat-humidity-sensing-brief.md).
# The ADPD188BI smoke sensor and the battery ADC are still to come. Layer 1.
idf_component_register(SRCS "src/siot_sensor.c" "src/hdc2080.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_timer esp_driver_i2c esp_driver_gpio esp_rom siot_board_def)
