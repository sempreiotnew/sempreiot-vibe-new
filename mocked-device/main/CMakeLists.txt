idf_component_register(SRCS "mocked-device.c"
                            "safr_frame.c"
                            "mesh_sim.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_driver_uart mbedtls esp_timer esp_hw_support)
